// dashboard.ts - agent-crew local web dashboard (Bun runtime, no build step).
//
// Launched by bin/ac-dashboard.sh as `bun run bin/dashboard.ts --port <N>`.
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

const BIN = import.meta.dir; // the fleet's bin/ (where this file lives)
const AC_HOME = process.env.AC_HOME ?? "";

// ---------------------------------------------------------------------------
// Pure parsers (exported for the Bun test). No IO, no re-derivation of any
// accounting - they format script/file output for the UI.
// ---------------------------------------------------------------------------

export interface BacklogView {
  in_flight: string[];
  queued: string[];
  done: string[];
}

/** Parse records/backlog.md into its three sections' task lines (§2.2). */
export function parseBacklog(md: string): BacklogView {
  const out: BacklogView = { in_flight: [], queued: [], done: [] };
  let section: keyof BacklogView | null = null;
  for (const raw of md.split("\n")) {
    const line = raw.replace(/\s+$/, "");
    const h = line.match(/^##\s+(.*)$/);
    if (h) {
      const t = h[1].trim().toLowerCase();
      if (t.startsWith("in flight") || t.startsWith("in-flight"))
        section = "in_flight";
      else if (t.startsWith("queued")) section = "queued";
      else if (t.startsWith("done")) section = "done";
      else section = null;
      continue;
    }
    if (section && /^\s*-\s+\[[ xX]\]/.test(line))
      out[section].push(line.trim());
  }
  return out;
}

export interface LearningPointer {
  name: string;
  sources: number;
  updated: string;
  legacy: "fleet" | "container" | null;
}

export interface LearningLedgerView {
  pending: string;
  pointers: LearningPointer[];
}

/**
 * Split the canonical two-section learning ledger without interpreting its raw
 * Pending records. Legacy rung-qualified pointers remain readable so the
 * dashboard can label a stray one migration-pending (the one-time
 * `ac-learn.sh migrate` ran on every home and is retired - a labeled pointer
 * now means someone wrote at a rung nothing reads).
 */
export function parseLearningLedger(md: string): LearningLedgerView {
  const normalized = md.replace(/\r\n?/g, "\n");
  const lines = normalized.split("\n");
  const pending: string[] = [];
  const pointers: LearningPointer[] = [];
  let section: "pending" | "distilled" | null = null;
  for (const line of lines) {
    if (/^##\s+Pending\s*$/.test(line)) {
      section = "pending";
      continue;
    }
    if (/^##\s+Distilled\s*$/.test(line)) {
      section = "distilled";
      continue;
    }
    const canonical = line.match(
      /\[distilled -> ([a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?)\]\s+sources=(\d+)\s+updated=([0-9]{4}-[0-9]{2}-[0-9]{2})/,
    );
    if (canonical) {
      pointers.push({
        name: canonical[1],
        sources: Number(canonical[2]),
        updated: canonical[3],
        legacy: null,
      });
      continue;
    }
    const legacy = line.match(
      /(?:^-\s+)?([0-9]{4}-[0-9]{2}-[0-9]{2})?.*?\[distilled -> ([a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?) @(fleet|container)\]/,
    );
    if (legacy) {
      pointers.push({
        name: legacy[2],
        sources: 1,
        updated: legacy[1] || "",
        legacy: legacy[3] as "fleet" | "container",
      });
      continue;
    }
    if (section === "pending") pending.push(line);
  }
  return {
    pending: pending.join("\n").replace(/^\n+|\n+$/g, ""),
    pointers,
  };
}

export interface BacklogHit {
  family: string; // the line's leading id token after the checkbox
  line: string; // the full backlog line, verbatim
  section: string; // "in flight" | "queued" | "done"
}

/**
 * Search a home's backlog markdown for task lines matching `q` (dash-search).
 * Reuses parseBacklog (never re-parses sections); a case-insensitive substring
 * over the FULL line covers BOTH id and text (the id is the line's first token),
 * and `family` is that leading `[a-z0-9-]+` token. Empty/whitespace `q` -> [].
 * Pure - the /api/search route supplies the md, so no path ever reaches the FS.
 */
export function matchBacklog(md: string, q: string): BacklogHit[] {
  const needle = q.trim().toLowerCase();
  if (!needle) return [];
  const bl = parseBacklog(md);
  const buckets: [keyof BacklogView, string][] = [
    ["in_flight", "in flight"],
    ["queued", "queued"],
    ["done", "done"],
  ];
  const out: BacklogHit[] = [];
  for (const [key, section] of buckets) {
    for (const line of bl[key]) {
      if (!line.toLowerCase().includes(needle)) continue;
      const m = line.match(/^-\s+\[[ xX]\]\s+([a-z0-9-]+)/);
      out.push({ family: m ? m[1] : "", line, section });
    }
  }
  return out;
}

export interface RoomRow {
  status: string; // the ac-room.sh list status token (PENDING-CAPTAIN(n)[+HANDBACK] | HANDBACK | ok)
  family: string;
  last: string;
  lastTs: number; // epoch ms of the last entry's ISO stamp; 0 when unparseable
  pending: boolean;
  handback: boolean;
}

/**
 * Parse `ac-room.sh list` output. The status token and counts are ac-room.sh's
 * own accounting (ac_room_pending); this only splits the line it already
 * emitted - it never re-counts pending/handback.
 * Line shape: `<status><spaces><family>\t<last>` (ac-room.sh cmd_list).
 * Rows come back newest-first by the last entry's own ISO stamp (a READ of what
 * the script printed, no extra IO); rows with no parseable stamp sink to the
 * bottom in ac-room.sh's emitted order (the sort is stable).
 */
export function parseRoomList(out: string): RoomRow[] {
  const rows: RoomRow[] = [];
  for (const line of out.split("\n")) {
    if (!line.trim()) continue;
    if (line.startsWith("(no rooms")) continue;
    const status = line.split(/\s+/, 1)[0];
    const tab = line.indexOf("\t");
    const left = tab >= 0 ? line.slice(0, tab) : line;
    const last = tab >= 0 ? line.slice(tab + 1) : "";
    const family = left.trim().split(/\s+/).pop() ?? "";
    if (!family || family === status) continue;
    const iso = last.match(/^-\s*\[(\d{4}-\d{2}-\d{2}T[0-9:.]+Z?)\]/);
    const ts = iso ? Date.parse(iso[1]) : NaN;
    rows.push({
      status,
      family,
      last,
      lastTs: Number.isNaN(ts) ? 0 : ts,
      pending: status.startsWith("PENDING-CAPTAIN"),
      handback: status === "HANDBACK" || status.endsWith("+HANDBACK"),
    });
  }
  rows.sort((a, b) => b.lastTs - a.lastTs);
  return rows;
}

export type ArtifactKind = "md" | "html" | "image" | "text";

export interface ArtifactMeta {
  family: string;
  stage: string; // the artifact's path WITHIN its family dir (dirs + basename)
  kind: ArtifactKind;
}

/** Image extensions the viewer previews inline (as a data: URL). */
const IMAGE_EXT = /\.(png|jpe?g|gif|webp|svg|bmp|ico|avif)$/i;

/**
 * Classify a file by its NAME for the list (filter chip + badge + the viewer's
 * first guess): markdown, html, image, else "text". "text" is optimistic - the
 * /api/artifact reader re-checks the bytes and downgrades a truly-binary file to
 * a "bin" note at view time. Pure; exported for the bun test.
 */
export function artifactKind(name: string): ArtifactKind {
  const n = name.toLowerCase();
  if (n.endsWith(".md") || n.endsWith(".markdown")) return "md";
  if (n.endsWith(".html") || n.endsWith(".htm")) return "html";
  if (IMAGE_EXT.test(n)) return "image";
  return "text";
}

/**
 * Derive {family, stage, kind} from an artifact's path RELATIVE to a home's
 * data/ dir (POSIX, forward-slash). Pure - the discovery walk supplies the rel
 * path, this only names it. There is NO allowlist: EVERY file under a family dir
 * is surfaced (captain's call - the Reports tree shows all folders/files), so
 * the only rejections are a path with no file under a family (< 2 segments) and a
 * family token that is not a plain id (guards traversal like `../etc/...`).
 *   <family>/report.md        -> stage "report.md",       kind "md"
 *   <family>/plan/report.md   -> stage "plan/report.md",  kind "md"
 *   <family>/review/x.json    -> stage "review/x.json",   kind "text"
 *   <family>/qa/evidence.png  -> stage "qa/evidence.png", kind "image"
 * `stage` is the full path within the family, so two files in one dir never
 * collide; the tree renders each segment as a folder and the basename as the leaf.
 * .lavish artifacts sit outside data/ and are labelled by the caller, not here.
 */
export function parseArtifactPath(rel: string): ArtifactMeta | null {
  const parts = rel.split("/").filter(Boolean);
  if (parts.length < 2) return null; // a file must sit under a family dir
  const family = parts[0];
  if (!/^[a-zA-Z0-9_-]+$/.test(family)) return null; // reject traversal / odd roots
  const stage = parts.slice(1).join("/"); // the path within the family (dirs + basename)
  return { family, stage, kind: artifactKind(parts[parts.length - 1]) };
}

/**
 * True iff a path names an HTML artifact. Matches the kind==="html" rule
 * above: the extension is `.html`, case-insensitively. Pure, and deliberately
 * ES5-plain like groupArtifacts - PAGE interpolates its toString(), so the
 * client gates the Review button by the very function bun proves.
 */
export function isHtmlArtifact(p: string): boolean {
  return String(p).slice(-5).toLowerCase() === ".html";
}

/**
 * True iff a path names an artifact the /review page can render: html or
 * markdown. The ONE gate every Review-affordance button keys on (Reports
 * viewer, Board detail viewer) - built on isHtmlArtifact so both surfaces
 * check the identical rule. Pure, ES5-plain like isHtmlArtifact - PAGE
 * interpolates its toString().
 */
export function reviewableArtifact(p: string): boolean {
  return isHtmlArtifact(p) || String(p).toLowerCase().endsWith(".md");
}

// ---------------------------------------------------------------------------
// Theme (theme-revamp). Pure resolution of the effective light/dark theme, so
// the CSS (:root default + prefers-color-scheme media block) and the test
// share ONE priority rule: an explicit stored choice wins, else
// prefers-color-scheme, else the dark default. Not interpolated into the
// pages - the browser never runs this resolution in JS, only in CSS - kept
// exported as the spec the CSS mirrors and bun test proves.
// ---------------------------------------------------------------------------
export function resolveTheme(stored: string | null, prefersLight: boolean): "light" | "dark" {
  if (stored === "light" || stored === "dark") return stored;
  return prefersLight ? "light" : "dark";
}
// Tri-state cycle over the STORED value (not the resolved theme): "auto" is no
// stored key at all, so resolveTheme's existing stored-vs-prefers-color-scheme
// fallback already renders it correctly with no change to that function.
export function nextTheme(current: "auto" | "light" | "dark"): "auto" | "light" | "dark" {
  return current === "auto" ? "light" : current === "light" ? "dark" : "auto";
}

// Palette (theme-revamp-presets): a second, independent axis from theme - only
// the accent group varies by palette, everything else varies by theme only.
// Cyan is the bare default (no stored key), mirroring how "auto" needs no
// stored theme key.
export function resolvePalette(stored: string | null): "cyan" | "teal" | "navy" {
  return stored === "teal" || stored === "navy" ? stored : "cyan";
}
export function nextPalette(current: "cyan" | "teal" | "navy"): "cyan" | "teal" | "navy" {
  return current === "cyan" ? "teal" : current === "teal" ? "navy" : "cyan";
}

// Background (dash-bg): a third client-side axis beside theme and palette -
// a custom canvas color and/or a wallpaper image, stored per browser
// (ac_dash_bg / ac_dash_bg_img / ac_dash_bg_dim) and applied pre-paint by
// THEME_INIT. Absent keys = the theme's own canvas, exactly like "auto".
/** A stored bg color is used only when it is a plain #rgb/#rrggbb hex -
 * anything else (an injected url(), var(), garbage) falls back to the theme. */
export function normalizeBgColor(stored: string | null): string | null {
  if (!stored) return null;
  const v = stored.trim().toLowerCase();
  return /^#([0-9a-f]{3}|[0-9a-f]{6})$/.test(v) ? v : null;
}
/** Wallpaper dim, 0 (image full-strength) .. 95 (barely there); anything
 * unparseable is the default 55. The image is painted at (100-dim)% opacity
 * over the canvas color, so readability degrades toward the theme, never
 * toward the photo. */
export function clampBgDim(stored: string | null): number {
  // Number(null) is 0, not NaN - an absent key must mean the default, never
  // a full-strength wallpaper.
  if (stored == null || stored.trim() === "") return 55;
  const n = Number(stored);
  if (!Number.isFinite(n)) return 55;
  return Math.min(95, Math.max(0, Math.round(n)));
}

// Shared palette, the ONE source for every page's <style> (captain-locked
// theme-revamp palette, extended by theme-revamp-presets). Dark is the :root
// default; an explicit data-theme override wins; absent a stored choice the OS
// preference decides via the media block. The -soft/-ink helpers can't be
// derived from the base tokens, so they are declared per theme here.
// Layout/alias/derived tokens (--bg, --purple-soft color-mix, fonts, --sb,
// shadows) stay in each page's own :root.
//
// PALETTE is a second, independent axis (data-palette="teal"|"navy"; cyan is
// the bare default, no attribute needed) - ONLY the --accent* group varies by
// palette, every other token above varies by theme (mode) only, so it is
// declared once per mode and never duplicated per palette. Each of the 3
// theme contexts (dark default, explicit light, auto-light-via-media) gets
// its own cyan-default accent group plus one override block per non-default
// palette, so the media block and the [data-theme="light"] block stay in
// step palette-for-palette, not just token-for-token.
// The 16 ANSI slots, per theme (captain: "apply theme/background như warp?").
// A terminal's TEXT colour is chosen by the agent, not by us, so painting only
// the ground is what made a light page unreadable: slots 7 and 15 are what a
// dark-ground TUI uses for ordinary text, and left as near-white they vanish.
// Warp's answer is the one taken here - remap the whole palette per theme - so
// the light set inverts the two ends (7/15 become dark) and darkens every hue
// enough to hold on #f3f5f7, while the dark set is the palette that was already
// hardcoded in ansiToHtml. One source, read by BOTH terminal surfaces: the
// snapshot pane emits var(--ansi-N), and the web terminal is handed the
// resolved values for xterm's own theme object.
const ANSI_DARK =
  "--ansi-0:#616161; --ansi-1:#ff8272; --ansi-2:#b4fa72; --ansi-3:#fefdc2; --ansi-4:#a5d5fe; --ansi-5:#ff8ffd; --ansi-6:#d0d1fe; --ansi-7:#f1f1f1;\n" +
  "    --ansi-8:#8e8e8e; --ansi-9:#ffc4bd; --ansi-10:#d6fcb9; --ansi-11:#fefdd5; --ansi-12:#c1e3fe; --ansi-13:#ffb1fe; --ansi-14:#e5e6fe; --ansi-15:#feffff;";
const ANSI_LIGHT =
  "--ansi-0:#24292f; --ansi-1:#cf222e; --ansi-2:#116329; --ansi-3:#9a6700; --ansi-4:#0969da; --ansi-5:#8250df; --ansi-6:#1b7c83; --ansi-7:#4b5563;\n" +
  "    --ansi-8:#57606a; --ansi-9:#a40e26; --ansi-10:#1a7f37; --ansi-11:#7d4e00; --ansi-12:#0550ae; --ansi-13:#6639ba; --ansi-14:#1b6f78; --ansi-15:#1d2530;";
const THEME_VARS = `
  :root{
    --canvas:#0e1116; --surface:#161b22; --elev:#1c232c; --border:#2a333f; --border-strong:#465061;
    --fg:#e6edf3; --fg2:#8b98a5;
    ${ANSI_DARK}
    --term-bg:#0c252d; --term-fg:#ffffff;
    --accent:#22d3ee; --accent-ink:#083344; --accent-soft:#122f33; --accent-hover:#10bad4;
    --success:#3fb950; --warning:#d29922; --error:#f85149; --stale:#a78bfa;
    --good-soft:#122820; --warn-soft:#2a2415; --err-soft:#2b1817;
  }
  :root[data-palette="teal"]{ --accent:#2dd4bf; --accent-ink:#04231f; --accent-soft:#123330; --accent-hover:#22b3a1; }
  :root[data-palette="navy"]{ --accent:#60a5fa; --accent-ink:#020617; --accent-soft:#121b33; --accent-hover:#3b82f6; }
  :root[data-theme="light"]{
    --canvas:#f3f5f7; --surface:#ffffff; --elev:#ffffff; --border:#e2e8f0; --border-strong:#cbd5e1;
    --fg:#1d2530; --fg2:#5c6673;
    ${ANSI_LIGHT}
    --term-bg:#f3f5f7; --term-fg:#1d2530;
    --accent:#0e7490; --accent-ink:#ffffff; --accent-soft:#eaf6f8; --accent-hover:#155e75;
    --success:#15803d; --warning:#a15c00; --error:#b42318; --stale:#6941c6;
    --good-soft:#e7f6ec; --warn-soft:#fbf0dc; --err-soft:#fbe9e7;
  }
  :root[data-theme="light"][data-palette="teal"]{ --accent:#0f766e; --accent-ink:#ffffff; --accent-soft:#eaf8f6; --accent-hover:#115e59; }
  :root[data-theme="light"][data-palette="navy"]{ --accent:#1e3a8a; --accent-ink:#ffffff; --accent-soft:#eaeef8; --accent-hover:#15306e; }
  @media (prefers-color-scheme: light){
    :root:not([data-theme]){
      --canvas:#f3f5f7; --surface:#ffffff; --elev:#ffffff; --border:#e2e8f0; --border-strong:#cbd5e1;
      --fg:#1d2530; --fg2:#5c6673;
      ${ANSI_LIGHT}
      --term-bg:#f3f5f7; --term-fg:#1d2530;
      --accent:#0e7490; --accent-ink:#ffffff; --accent-soft:#eaf6f8; --accent-hover:#155e75;
      --success:#15803d; --warning:#a15c00; --error:#b42318; --stale:#6941c6;
      --good-soft:#e7f6ec; --warn-soft:#fbf0dc; --err-soft:#fbe9e7;
    }
    :root:not([data-theme])[data-palette="teal"]{ --accent:#0f766e; --accent-ink:#ffffff; --accent-soft:#eaf8f6; --accent-hover:#115e59; }
    :root:not([data-theme])[data-palette="navy"]{ --accent:#1e3a8a; --accent-ink:#ffffff; --accent-soft:#eaeef8; --accent-hover:#15306e; }
  }`;

// UX baseline (ui-ux-pro-max audit, captain-ordered refactor 2026-08-13),
// injected into every captain-facing page's <style> right after THEME_VARS -
// deliberately NOT into IFRAME_STYLE, whose artifact internals stay put.
// One rule per finding, additive so page-local CSS stays authoritative:
// - focus-states: keyboard focus was invisible on buttons/links across the
//   app (11 :focus rules total, all inputs); :focus-visible only, so mouse
//   clicks stay ringless and input :focus styling is untouched.
// - cursor/touch: pointer affordance + touch-action on every interactive
//   element (34 scattered cursor:pointer rules did not cover buttons).
// - state-transition: hover/active snapped (8 transitions app-wide); one
//   shared 150ms ease-out rhythm (motion-consistency), colors/opacity only.
// - disabled-states: reduced opacity + not-allowed cursor.
// - number-tabular: data columns (counts, timers) stop shifting in --ui
//   contexts; the mono font is already tabular.
// - reduced-motion: honored globally instead of per-page.
const UX_BASE = `
  :focus-visible{outline:2px solid var(--accent);outline-offset:2px}
  button,a,summary,[role="button"]{cursor:pointer;touch-action:manipulation}
  button:disabled{opacity:.45;cursor:not-allowed}
  button,a{transition:background-color .15s ease-out,color .15s ease-out,border-color .15s ease-out,opacity .15s ease-out}
  body{font-variant-numeric:tabular-nums}
  @media (prefers-reduced-motion:reduce){*,*::before,*::after{animation-duration:.01ms!important;transition-duration:.01ms!important}}
`;

// Pre-paint theme + palette application: apply an explicit stored choice for
// BOTH axes before first render so there is no dark->light (or palette) flash.
// No stored choice for either key = no attribute, so the CSS :root default +
// prefers-color-scheme media block above decide. Shared by all four pages
// (theme-revamp-presets), so every page gets the chosen palette for free even
// though only PAGE offers a control for it.
const THEME_INIT = `<script>(function(){try{var t=localStorage.getItem('ac_dash_theme');if(t==='light'||t==='dark')document.documentElement.setAttribute('data-theme',t);var p=localStorage.getItem('ac_dash_palette');if(p==='teal'||p==='navy')document.documentElement.setAttribute('data-palette',p);var st=document.documentElement.style;var c=localStorage.getItem('ac_dash_bg');if(c&&/^#([0-9a-f]{3}|[0-9a-f]{6})$/.test(c.trim().toLowerCase()))st.setProperty('--canvas',c.trim());var im=localStorage.getItem('ac_dash_bg_img');if(im&&im.slice(0,11)==='data:image/'){var dr=localStorage.getItem('ac_dash_bg_dim');var d=(dr==null||dr==='')?55:Number(dr);if(!isFinite(d))d=55;d=Math.min(95,Math.max(0,Math.round(d)));st.setProperty('--bg-img','url("'+im+'")');st.setProperty('--bg-img-op',String((100-d)/100));}}catch(e){}})();</script>`;

// The markdown "reader" typography + table rules (review-page-missing-markdown-table-css),
// shared verbatim between PAGE's SPA views (scoped under .reader, since other
// page chrome shares the same document - readerCss(".reader")) and the
// /review artifact iframe (the whole srcdoc document IS reader content, no
// scoping needed - readerCss("")). One authoritative rule set per
// THEME_VARS/THEME_INIT's own precedent (repo-knowledge #319): a new reader
// rule updates both surfaces by construction, never by hand-copying text.
export function readerCss(scope: string): string {
  const s = scope ? scope + " " : "";
  const self = scope || "body";
  return `${s}.mmdview{ margin:12px 0; padding:10px; background:var(--surface); border:1px solid var(--border); border-radius:8px; overflow-x:auto; }
  ${s}.mmdview svg{ max-width:100%; height:auto; }
  ${self}{ font-size:15px; line-height:1.6; max-width:82ch; }
  ${s}h1,${s}h2,${s}h3,${s}h4,${s}h5,${s}h6{ color:var(--fg); margin:20px 0 8px; line-height:1.3; }
  ${s}h1{ font-size:1.6em; } ${s}h2{ font-size:1.3em; } ${s}h3{ font-size:1.12em; }
  ${s}p{ margin:8px 0; }
  ${s}ul,${s}ol{ margin:8px 0; padding-left:24px; }
  ${s}li{ margin:2px 0; }
  ${s}code{ font-family:var(--mono); font-size:.88em; background:var(--canvas); border:1px solid var(--border); border-radius:4px; padding:0 4px; }
  ${s}pre{ font-family:var(--mono); font-size:.86em; background:var(--canvas); border:1px solid var(--border); border-radius:6px; padding:12px 14px; overflow:auto; }
  ${s}pre code{ background:none; border:none; padding:0; }
  ${s}a{ color:var(--accent); }
  ${s}.tablewrap{ overflow-x:auto; margin:12px 0; }
  ${s}table{ border-collapse:collapse; font-size:.92em; }
  ${s}th,${s}td{ border:1px solid var(--border); padding:5px 10px; text-align:left; vertical-align:top; }
  ${s}thead th{ background:var(--surface); font-weight:600; white-space:nowrap; }`;
}

/** The review iframe's srcdoc is composed HERE, the one place that decides
 * whether an artifact gets the reader stylesheet + resolved theme/palette:
 * kind:"md" is a bare fragment from renderMarkdown, styled and given the
 * theme attrs the outer document already resolved; every other kind (chiefly
 * kind:"html", which carries its own stylesheet) passes through untouched -
 * no style, no <html> wrapper, byte-identical to what artifactShow returned. */
export function buildReviewSrcdoc(kind: string, content: string, styleBlock: string, theme: string, palette: string): string {
  if (kind !== "md") return content;
  const attrs = (theme ? ` data-theme="${theme}"` : "") + (palette ? ` data-palette="${palette}"` : "");
  return `<html${attrs}>${styleBlock}` + content;
}

// ---------------------------------------------------------------------------
// Board + task-detail (dashboard-board). DISPLAY != STORAGE: every field below
// is DERIVED at render time by LINKING data that already exists on disk, joined
// by the family id - ZERO new stored fields. These are pure joiners (exported
// for the bun test); the composer takes already-read data so it never touches
// the FS. The one aggregator endpoint /api/family calls composeFamily; the board
// itself joins the existing /api/backlog + /api/reports client-side by family id.
// ---------------------------------------------------------------------------

export interface BacklogLineFields {
  id: string; // leading task-id token, "" if the string is not a task line
  text: string; // one-line description after the first " - " (full remainder)
  repo: string; // the `repo:<name>` token, "" if absent
  pr: string; // a GitHub PR url on the line (QĐ1 link-only regex), "" if none
  merged: string; // date inside "(merged <date>)", "" if none
  epic: string; // `epic:<id>` membership token (a story's parent), "" if none
  isEpic: boolean; // the line carries an [EPIC...] marker (it IS an epic)
  contract: string; // delivery-contract group content ("src:cap mode:local-only ..."), "" if none
}

/**
 * Parse ONE backlog line into the fields the board card + detail render (§9
 * grammar). Pure regex over the SAME raw string parseBacklog keeps - the fields
 * live inside that string and are never stored broken out (captain's principle).
 */
export function parseBacklogLine(line: string): BacklogLineFields {
  const s = String(line || "");
  var idm = s.match(/^-\s*\[[ xX]\]\s+([a-z0-9][a-z0-9-]*)/);
  var id = idm ? idm[1] : "";
  // Walk the LEADING RUN of bracket groups after the id (backtick-quoted
  // documentation mentions included). Two derivations hang off this walk:
  //   - the TEXT boundary is the first " - " AFTER the run - a prose group
  //     whose content contains " - " (a verbatim captain quote, a dated
  //     provenance note) used to cut the text mid-bracket;
  //   - the delivery-contract group (§9) is readable only INSIDE the run
  //     (position denies authority everywhere else). Discriminator per the
  //     awk twin (AC_DONELINE_AWK, ac-lib.sh): EVERY whitespace-separated
  //     token is key:value from the closed key set - any other content
  //     keeps the group's existing class ([EPIC...], [@held], prose) -
  //     first such group wins, a backtick-wrapped group never counts.
  var contract = "";
  var pos = idm ? idm[0].length : 0;
  if (id) {
    for (;;) {
      var g = /^\s+(`?)\[([^\]]*)\](`?)/.exec(s.slice(pos));
      if (!g) break;
      pos += g[0].length;
      if (contract || g[1] === "`" || g[3] === "`") continue;
      var content = g[2].trim();
      if (!content) continue;
      var toks = content.split(/\s+/);
      var all = true;
      for (var ti = 0; ti < toks.length; ti++)
        if (!/^(src|flow|mode|rev|qa|promote):[a-z][a-z-]*$/.test(toks[ti])) { all = false; break; }
      if (all) contract = content;
    }
  }
  const dash = s.indexOf(" - ", id ? pos : 0);
  const text = dash >= 0 ? s.slice(dash + 3).trim() : "";
  const repo = (s.match(/\brepo:\s*([a-z0-9][a-z0-9._-]*)/i) || ["", ""])[1];
  const pr = (s.match(/https?:\/\/github\.com\/[^\s)]+\/pull\/\d+/) || [""])[0] || "";
  const merged = (s.match(/\(merged\s+([0-9]{4}-[0-9]{2}-[0-9]{2})/) || ["", ""])[1];
  const epic = (s.match(/\bepic:([a-z0-9][a-z0-9-]*)/) || ["", ""])[1];
  return { id, text, repo, pr, merged, epic, isEpic: /\[EPIC/i.test(s), contract };
}

/**
 * Split one contract-group string ("src:cap mode:local-only ...") into
 * {k, v} chip pairs for render. Order preserved (the row's own order is the
 * captain's record). ES5-plain so PAGE interpolates its toString() - the
 * board card, the detail block, and the backlog rows all run the SAME
 * bun-tested split.
 */
export function contractTokens(contract: string): { k: string; v: string }[] {
  var out: { k: string; v: string }[] = [];
  var toks = String(contract || "").split(/\s+/);
  for (var i = 0; i < toks.length; i++) {
    var c = toks[i].indexOf(":");
    if (c <= 0) continue;
    out.push({ k: toks[i].slice(0, c), v: toks[i].slice(c + 1) });
  }
  return out;
}

/**
 * The KNOWN-FAMILY set for a route that renders task ids but never the ledger
 * (Processes). Deliberately the same derivation the Board's own `boardData`
 * runs client-side - both walk the three sections through `parseBacklogLine` -
 * so one task id normalizes identically wherever it is shown. De-duped because
 * `familyOfTaskId` only asks whether an id is present.
 */
export function backlogFamilyIds(b: BacklogView): string[] {
  const out: string[] = [];
  const seen: { [k: string]: 1 } = {};
  for (const arr of [b.in_flight, b.queued, b.done])
    for (const line of arr || []) {
      const id = parseBacklogLine(line).id;
      if (id && !seen[id]) {
        seen[id] = 1;
        out.push(id);
      }
    }
  return out;
}

/**
 * Derive a story's five-state board value (done/in_flight/queued/failed/
 * abandoned) from a backlog line + its known section. Section alone is only
 * in_flight/queued/done (boardData's childrenOf entries carry {id, line,
 * section}, :6472) and parseBacklogLine drops the marker anyway (its text
 * starts after the first " - ", the marker sits before that boundary) - so
 * neither, alone, can distinguish a real done from a [failed]/[abandoned]
 * row. This re-reads the RAW line's own prefix - the same boundary
 * parseBacklogLine uses - so a description mentioning the words
 * "failed"/"abandoned" past that boundary never false-positives.
 * composeFamily calls this directly for three things now: the epic rollup's
 * done count, each child's exposed `state` (board-rollup-and-overlay-count-
 * failed-as-done fixed the prior `done: c.section === "done"` bug here), and
 * the FAMILY'S OWN `state` (same-done-miscount-in-three-more-surfaces), which
 * feeds deriveProgress (never "done"/merged-date for a [failed]/[abandoned]
 * family) and is what boardCard's own-card badge, familyDetailHtml's header
 * pill, and boardOverview's Status line all read - none of them re-derive it.
 * The overview's story cards read the composeFamily-derived child `state`
 * rather than re-deriving it, and boardCard's chip sub-list calls this
 * function directly off the raw line it already holds client-side (the one
 * remaining direct caller, since it has no composeFamily result per child
 * line). One state derivation, every render reuses it - never a second
 * marker parser. realDoneCount (headMeta) also calls this directly for the
 * backlog/board route header counters. Self-contained so PAGE interpolates
 * its toString() and the bun test proves the same code the browser runs.
 */
export function storyState(
  line: string,
  section: string | null | undefined,
): "done" | "in_flight" | "queued" | "failed" | "abandoned" {
  if (section === "in_flight" || section === "queued") return section;
  var s = String(line || "");
  var dash = s.indexOf(" - ");
  var head = dash >= 0 ? s.slice(0, dash) : s;
  if (/\[failed\]/i.test(head)) return "failed";
  if (/\[abandoned\]/i.test(head)) return "abandoned";
  return "done";
}

/**
 * Normalize a live task id to its bare family id so the snapshot's per-task
 * status joins a family card (§5 join-key hazard: status is keyed by
 * `<family>-<stage>`/`<family>-chief`, everything else by the bare family). The
 * suffix set is verified against state/*.meta + state/archive: `-chief`
 * (roomchief) and the stage tokens, with an optional `-r<n>` review round;
 * `-scout` is deliberately absent (a scout id IS its own family). The collision
 * guard: strip ONLY when `known` confirms the base is a real family, so a family
 * literally named `<x>-design` (e.g. plan-first-design) is never mis-folded onto
 * `<x>`. With no `known` the strip is unconditional. Self-contained (regex
 * inlined) so PAGE can interpolate its toString() for the client join.
 */
export function familyOfTaskId(id: string, known?: string[]): string {
  var s = String(id || "");
  var suffix = /-(chief|discovery|spec|arch|architecture|design|breakdown|plan|implement|qa)(-r\d+)?$/;
  var knows = function (f: string) { return !!known && known.indexOf(f) >= 0; };
  if (knows(s)) return s; // the id itself is a family - never strip
  var base = s.replace(suffix, "");
  if (base === s) return s; // no recognized suffix
  if (known) return knows(base) ? base : s; // strip only onto a real family
  return base;
}

/**
 * The In-Flight column's LIVE-pane join (board-live-panes): system/paned tasks
 * that run with a live meta but mint NO backlog row - a `verify-suite` gate run,
 * a `learning` roomchief, a `self` chief edit - never appear as backlog `## In
 * flight` rows, so the Board read idle while machinery ran. This is a DERIVED
 * join at render time: read the live panes off the snapshot the client already
 * holds (crew.tasks + the verify[] bucket - the SAME meta reader ac-fleets.sh
 * feeds Processes), drop any whose FAMILY already has an In-flight backlog card
 * (dedupe by family id, mirroring composeFamily's join key, so a real execution
 * task shows ONCE as its card while its live status flows through boardLive), and
 * return the rest for the system-card variant. Zero new storage. Pure + ES5-plain
 * so PAGE interpolates its toString() - the browser runs the bun-tested code.
 */
export function boardSystemPanes(
  home: { crew?: { tasks?: any[] } | null; verify?: any[] | null } | null | undefined,
  known: string[],
  inflightIds: string[],
): { id: string; kind: string; project: string; status: string }[] {
  var seen: { [k: string]: 1 } = {};
  var ids = inflightIds || [];
  for (var j = 0; j < ids.length; j++) seen[ids[j]] = 1;
  var out: { id: string; kind: string; project: string; status: string }[] = [];
  var add = function (p: any) {
    if (!p || !p.id) return;
    if (seen[familyOfTaskId(p.id, known)]) return; // already an In-flight card
    out.push({ id: p.id, kind: p.kind || "task", project: p.project || "—", status: p.status || "" });
  };
  var tasks = (home && home.crew && home.crew.tasks) || [];
  for (var i = 0; i < tasks.length; i++) add(tasks[i]);
  var vr = (home && home.verify) || [];
  for (var v = 0; v < vr.length; v++) add(vr[v]);
  return out;
}

export interface Progress {
  pct: number;
  label: string;
}

/**
 * Derive a COARSE progress bar/label (QĐ2) - a composite of the backlog section
 * plus completed-stage count, never a stored % (none exists on disk). Pure;
 * an optional last-status line (client-only, from the snapshot) surfaces as the
 * in-flight label.
 */
export function deriveProgress(input: {
  section: string | null;
  stagesDone?: number;
  merged?: string;
  status?: string;
  state?: "done" | "in_flight" | "queued" | "failed" | "abandoned";
}): Progress {
  const sec = input.section || "";
  const done = input.stagesDone || 0;
  // A [failed]/[abandoned] row is terminal but never "done" (same-done-
  // miscount-in-three-more-surfaces) - checked before the section branch
  // below, since section alone (§storyState) cannot distinguish a real done
  // from a failed/abandoned Done-section row.
  if (input.state === "failed" || input.state === "abandoned") return { pct: 100, label: input.state };
  if (sec === "done")
    return { pct: 100, label: input.merged ? "merged " + input.merged : "done" };
  if (sec === "queued") return { pct: 0, label: "queued" };
  if (sec === "in_flight") {
    return {
      pct: Math.min(90, 10 + done * 20),
      label: (input.status && String(input.status).trim()) || "in flight",
    };
  }
  return { pct: 0, label: "" };
}

export interface TimelineEvent {
  ts: string; // the raw iso-8601 timestamp (ac_status_append shape)
  line: string; // the event text
  deltaMs: number; // ms since the previous event (0 for the first / unparseable)
}

/**
 * Parse a task's durable timeline.log (optionally merged with a live
 * state/<id>.status tail) into ordered events with per-step deltas
 * (task-timeline). Each source line is `<iso-ts> <event text>` - the one shape
 * ac_status_append writes to BOTH files, so the two mirror each other; a merge
 * therefore dedupes by exact (ts,text) to never double-count. Events sort by
 * timestamp and each carries deltaMs = ms since the previous event, so "each
 * step's duration" renders at a glance. Pure and ES5-plain so PAGE interpolates
 * its toString() and the bun test proves the same code the browser runs.
 */
export function parseTimeline(text: string): TimelineEvent[] {
  var lines = String(text || "").split("\n");
  var seen: Record<string, boolean> = {};
  var evs: { ts: string; line: string; ms: number }[] = [];
  for (var i = 0; i < lines.length; i++) {
    var raw = (lines[i] || "").replace(/\r$/, "");
    if (!raw) continue;
    var sp = raw.indexOf(" ");
    if (sp < 0) continue;
    var ts = raw.slice(0, sp);
    var rest = raw.slice(sp + 1);
    if (!ts || !rest) continue;
    var key = ts + "\x00" + rest;
    if (seen[key]) continue;
    seen[key] = true;
    var ms = Date.parse(ts);
    evs.push({ ts: ts, line: rest, ms: isNaN(ms) ? 0 : ms });
  }
  evs.sort(function (a, b) { return a.ms - b.ms; });
  var out: TimelineEvent[] = [];
  for (var j = 0; j < evs.length; j++) {
    var e = evs[j];
    var prev = j > 0 ? evs[j - 1].ms : 0;
    var delta = j > 0 && e.ms && prev ? e.ms - prev : 0;
    out.push({ ts: e.ts, line: e.line, deltaMs: delta < 0 ? 0 : delta });
  }
  return out;
}

export interface StageArtifact {
  name: string; // the file's basename (final-design.html, report.md)
  path: string; // absolute path (the viewer route resolves + gates it again)
  id: string; // rel-path id for a Reports-route deep link
  kind: string; // md | html | image | text | ... (from collectArtifacts)
}

export interface FamilyStage {
  stage: string; // the immediate subdir under data/<family>/ (or "report" for a flat family)
  report: string; // absolute path to that stage's report.md, "" if none
  id: string; // the report artifact's id (rel path) for a Reports-route link, "" if none
  path: string; // absolute path of a representative file in the stage (for display)
  artifacts: StageArtifact[]; // EVERY file in the stage (v2 detail tree renders each inline)
}

/**
 * Build a family's stage timeline (dashboard-board-v2). Each immediate subdir
 * under data/<family>/ that holds files is a stage; the subdir's report.md makes
 * it "complete" and links that report, and the stage carries the FULL file list
 * so the v2 detail can render each artifact inline (design/*.html, plan/report.md
 * ...). Every family-root file (report.md, brief.md, room.md, ...) joins the
 * same "report" stage, except a `*.session.json` sidecar (review-loop machinery
 * the Reviews page already surfaces) - only report.md still marks the stage
 * complete. Pure; the caller hands the already-read artifact list in. Self-contained (STAGE_ORDER inlined)
 * so PAGE interpolates its toString() and the Board CARD + detail run the SAME
 * composer the bun test proves. `plan` sits after `design`, before `implement`
 * (plan-first: a data/<family>/plan/ dir sorts as a proper stage).
 */
export function familyStages(
  artifacts: { family: string; stage: string; kind: string; path: string; id: string }[],
  family: string,
): { stages: FamilyStage[]; designHtml: { stage: string; path: string; id: string }[] } {
  var STAGE_ORDER = ["discovery","spec","arch","architecture","design","plan","implement","qa","report","lavish"];
  var mine = (artifacts || []).filter(function (a) { return a.family === family; });
  var stageMap: Record<string, { report: string; id: string; path: string; artifacts: StageArtifact[] }> = {};
  for (var mi = 0; mi < mine.length; mi++) {
    var a = mine[mi];
    var parts = a.stage.split("/").filter(Boolean);
    if (!parts.length) continue;
    var base = parts[parts.length - 1];
    var stage: string;
    if (parts.length === 1) {
      if (base.endsWith(".session.json")) continue; // review-loop sidecar; Reviews page already surfaces it
      stage = "report"; // every other root file (brief.md, room.md, ...) joins the report stage
    } else {
      stage = parts[0];
    }
    if (!stageMap[stage]) stageMap[stage] = { report: "", id: "", path: "", artifacts: [] };
    if (!stageMap[stage].path) stageMap[stage].path = a.path;
    if (base === "report.md") { stageMap[stage].report = a.path; stageMap[stage].id = a.id; }
    stageMap[stage].artifacts.push({ name: base, path: a.path, id: a.id, kind: a.kind });
  }
  var stages: FamilyStage[] = Object.keys(stageMap)
    .map(function (k) { var m = stageMap[k]; return { stage: k, report: m.report, id: m.id, path: m.path, artifacts: m.artifacts }; })
    .sort(function (a, b) {
      var ia = STAGE_ORDER.indexOf(a.stage);
      var ib = STAGE_ORDER.indexOf(b.stage);
      var ra = ia < 0 ? 99 : ia;
      var rb = ib < 0 ? 99 : ib;
      if (ra !== rb) return ra - rb;
      return a.stage < b.stage ? -1 : a.stage > b.stage ? 1 : 0;
    });
  var designHtml = mine
    .filter(function (a) { return a.kind === "html"; })
    .map(function (a) { return { stage: a.stage, path: a.path, id: a.id }; });
  return { stages: stages, designHtml: designHtml };
}

/** One PR the family raised, wherever it was recorded (board-detail-repos-prs). */
export interface FamilyPr {
  url: string;
  repo: string; // the repo it was raised in, "" when nothing named one
  task: string; // the task id whose meta recorded it, "" for a backlog-line PR
  family: string; // the owning family - a STORY id on an epic's detail
  merged: boolean;
}

export interface FamilyDetail {
  family: string;
  id: string;
  text: string;
  state: "done" | "in_flight" | "queued" | "failed" | "abandoned";
  section: string;
  repo: string;
  repos: string[]; // EVERY repo the family's work touches (see composeFamily)
  isEpic: boolean;
  epic: string;
  pr: string;
  prs: FamilyPr[]; // EVERY PR the family raised, not only the line's one link
  merged: string;
  progress: Progress;
  stages: FamilyStage[];
  designHtml: { stage: string; path: string; id: string }[];
  timeline: TimelineEvent[];
  roomEntries: string[];
  roomCount: number;
  children: {
    id: string;
    done: boolean;
    state: "done" | "in_flight" | "queued" | "failed" | "abandoned";
    section: string;
    text: string;
    repo: string; // the story's OWN repo (multi-repo epic story tree)
    pr: string; // the story's OWN PR url, "" if none
    stages: FamilyStage[]; // the story's OWN stages/artifacts, rendered inline
  }[];
  rollup: { done: number; total: number } | null;
  links: { label: string; kind: string; path: string }[];
  contract: string; // the row's delivery-contract group content, "" if none
}

/**
 * EVERY repo one family's work touches. ONE family can span several - an epic
 * whose stories each land in their own, and a plain family whose per-repo
 * sibling tasks each lease a different one (measured on a live home: one
 * family, four siblings, four repos, four PRs). Its §9 line then carries the
 * placeholder `repo: multi`, which names no repo at all, so the list is DERIVED
 * from three sources: the line's own token, every member task's `project=` (the
 * only place a sibling's repo exists), and every story's own token. `multi` is
 * dropped; FamilyDetail.repo keeps the raw token for the surfaces that still
 * render exactly one string. Shared: composeFamily derives `repos` with it and
 * familyDetail resolves the Linked-knowledge files with it, so the two can
 * never disagree about which repos a family has. Self-contained (ES5-plain) so
 * PAGE interpolates its toString().
 */
export function familyRepos(
  lineRepo: string,
  tasks: { repo: string }[],
  children: { line: string }[],
): string[] {
  var out: string[] = [];
  var add = function (name: string) {
    var r = String(name || "").trim();
    if (!r || r.toLowerCase() === "multi") return;
    if (out.indexOf(r) < 0) out.push(r);
  };
  add(lineRepo);
  for (var i = 0; i < (tasks || []).length; i++) add(tasks[i].repo);
  for (var c = 0; c < (children || []).length; c++) add(parseBacklogLine(children[c].line).repo);
  return out;
}

/**
 * Compose the per-family detail panel (QĐ3) by LINKING already-read data: the
 * family's backlog line, its on-disk artifact list, its room entries, and its
 * epic stories - all keyed by the family id. Pure: the caller does the IO and
 * hands the data in, so this composition is unit-tested with no FS. Self-contained
 * (STAGE_ORDER inlined) so PAGE interpolates its toString() and the Board CARD
 * runs the SAME composer as the /api/family detail - one joiner, zero drift.
 */
export function composeFamily(input: {
  family: string;
  line: string | null;
  section: string | null;
  project: string;
  artifacts: { family: string; stage: string; kind: string; path: string; id: string }[];
  roomEntries: string[];
  children: { id: string; line: string; section: string }[];
  knowledgeRepos: string[]; // the family's repos that HAVE a records/repo-knowledge/<repo>.md
  learningsCiteFamily: boolean; // the learnings ledger names this family (never merely exists)
  timelineText?: string;
  tasks?: { id: string; family: string; repo: string; pr: string; prMerged: boolean }[];
}): FamilyDetail {
  const fields = parseBacklogLine(input.line || "");
  // Stage timeline + design html for THIS family (familyStages inlines
  // STAGE_ORDER and the per-stage artifact grouping - one joiner, zero drift).
  const own = familyStages(input.artifacts || [], input.family);
  const stages = own.stages;
  const designHtml = own.designHtml;

  // Each epic story is its OWN family: carry its repo + PR (from its own backlog
  // line) and its OWN stages/artifacts, so the detail's multi-repo story tree
  // renders each story's ck:plan/report inline without a cross-family read.
  // The same pass collects each story's PR for the family-wide list below - one
  // parse of the line, not a second one to re-read its `(merged <date>)` token.
  const childPrs: FamilyPr[] = [];
  const children = (input.children || []).map((c) => {
    const cf = parseBacklogLine(c.line);
    const state = storyState(c.line, c.section);
    if (cf.pr)
      childPrs.push({ url: cf.pr, repo: cf.repo, task: "", family: c.id, merged: !!cf.merged });
    return {
      id: c.id,
      done: state === "done",
      state,
      section: c.section,
      text: cf.text,
      repo: cf.repo,
      pr: cf.pr,
      stages: familyStages(input.artifacts || [], c.id).stages,
    };
  });
  // Rollup only when the epic actually has story lines in the backlog; a folded
  // 1-task epic (marker but no `epic:<id>` children) would otherwise read "0/0".
  const rollup = children.length
    ? { done: children.filter((c) => c.done).length, total: children.length }
    : null;

  const stagesDone = stages.filter((s) => s.report).length;
  // The family's OWN terminal state, reusing storyState the same way children
  // already do above - so a standalone [failed]/[abandoned] family's progress
  // label never reads "done" either (same-done-miscount-in-three-more-surfaces).
  const ownState = storyState(input.line || "", input.section);
  const progress = deriveProgress({ section: input.section, stagesDone, merged: fields.merged, state: ownState });

  // Linked (reused): the knowledge an intake on THIS family was obliged to read
  // (AGENTS.md section 5). ONE row per repo that actually has a record - a
  // multi-repo family reads several, and the single `repo:` token used to hide
  // all but one of them (a `multi` token hid every one). The learnings row is
  // conditional on the ledger CITING this family, not on the ledger existing:
  // records/learnings.md exists in every home, so the unconditional row said the
  // same thing on every family in every fleet and told the reader nothing.
  const links: { label: string; kind: string; path: string }[] = [];
  for (const repo of input.knowledgeRepos || [])
    links.push({
      label: "repo-knowledge/" + repo,
      kind: "knowledge",
      path: "records/repo-knowledge/" + repo + ".md",
    });
  if (input.learningsCiteFamily)
    links.push({ label: "learnings ledger", kind: "learnings", path: "learnings.md" });

  const roomEntries = input.roomEntries || [];

  const tasks = input.tasks || [];
  const repos = familyRepos(fields.repo || input.project, tasks, input.children || []);
  const realRepo = (name: string) => (String(name || "").trim().toLowerCase() === "multi" ? "" : String(name || "").trim());

  // Every PR the family raised. The backlog line linkifies at most ONE, but each
  // crewmate/roomchief records its own on its task meta (ac-pr-check.sh writes
  // pr=, ac-pr-merge.sh pr_merged=1) - the only record a per-repo sibling's PR
  // has. Metas go in FIRST because they carry the task id and the merged flag;
  // the line-derived ones only fill in a URL no meta claimed. Deduped by URL.
  // A LINE's PR takes its repo from the URL, never from the line's own `repo:`
  // token: a multi-repo row lists several PRs and parseBacklogLine linkifies the
  // FIRST, which need not be the one that token names (measured: a row tokened
  // for one repo whose first link points at another).
  const prRepo = (url: string) => (String(url || "").match(/github\.com\/[^/]+\/([^/]+)\/pull\//) || ["", ""])[1];
  const prs: FamilyPr[] = [];
  const seenPr: { [url: string]: 1 } = {};
  const addPr = (p: FamilyPr) => {
    if (!p.url || seenPr[p.url]) return;
    seenPr[p.url] = 1;
    prs.push(p);
  };
  for (const t of tasks)
    addPr({ url: t.pr, repo: realRepo(t.repo), task: t.id, family: t.family, merged: !!t.prMerged });
  addPr({ url: fields.pr, repo: prRepo(fields.pr) || realRepo(fields.repo), task: "", family: input.family, merged: !!fields.merged });
  for (const p of childPrs)
    addPr({ url: p.url, repo: prRepo(p.url) || realRepo(p.repo), task: p.task, family: p.family, merged: p.merged });

  return {
    family: input.family,
    id: fields.id || input.family,
    text: fields.text,
    state: ownState,
    section: input.section || "",
    repo: fields.repo || input.project,
    repos,
    isEpic: fields.isEpic,
    epic: fields.epic,
    pr: fields.pr,
    prs,
    merged: fields.merged,
    progress,
    stages,
    designHtml,
    timeline: parseTimeline(input.timelineText || ""),
    roomEntries,
    roomCount: roomEntries.length,
    children,
    rollup,
    links,
    contract: fields.contract,
  };
}

/**
 * The per-fleet learning-loop label - "learn <n>/<X> · curate <m>/<Y>" plus the
 * warn flag - shared by the fleet card and the Processes header so the two can
 * never drift into two different labels. Every number AND the due flag come
 * from the snapshot's per-home cadence block (ac-fleets.sh, where the `>=`
 * lives); no threshold is re-derived here. A cadence that is absent or
 * half-formed renders NOTHING (null), never a stray "0/0". Markup-free, and
 * deliberately ES5-plain like groupArtifacts - PAGE interpolates its toString().
 */
export function cadenceLabel(c: any): { text: string; due: boolean } | null {
  var l = c && c.learn, u = c && c.curate;
  var ok = function (o) { return !!o && typeof o.count === "number" && typeof o.every === "number"; };
  if (!ok(l) || !ok(u)) return null;
  return {
    text: "learn " + l.count + "/" + l.every + " · curate " + u.count + "/" + u.every,
    due: !!(l.due || u.due),
  };
}

/**
 * The Fleets page's needs-captain QUEUE: every concrete item across the
 * container that waits on the captain, as one flat actionable list - pending
 * gates/asks first, then hand-backs, then watcher-down alerts (decisions the
 * captain OWES rank above infrastructure), original home order kept inside
 * each band. Walks each home's `crewdeputies` too (one level - the snapshot
 * nests no deeper), so a deputy's stuck gate is as visible as its parent's.
 * The counts in the attention strip already exist; this is the list behind
 * them, so the captain jumps to the family instead of hunting it. Pure and
 * ES5-plain - PAGE interpolates its toString(), the bun test proves the same
 * code the browser runs.
 */
export function fleetAttnItems(snap: any): { fleet: string; kind: string; family: string; text: string }[] {
  var pend = [], hand = [], watch = [];
  var homes = (snap && snap.homes) || [];
  var flat = [];
  for (var i = 0; i < homes.length; i++) {
    flat.push(homes[i]);
    var deps = homes[i] && homes[i].crewdeputies;
    if (deps && deps.length) for (var d = 0; d < deps.length; d++) flat.push(deps[d]);
  }
  for (var j = 0; j < flat.length; j++) {
    var h = flat[j]; if (!h || !h.name) continue;
    var entries = (h.inbox && h.inbox.entries) || [];
    for (var e = 0; e < entries.length; e++) {
      var en = entries[e] || {};
      var st = String(en.status || "");
      var it = { fleet: String(h.name), family: String(en.family || ""), text: String(en.last || "") };
      if (st.indexOf("PENDING-CAPTAIN") === 0)
        pend.push({ fleet: it.fleet, kind: "pending", family: it.family, text: it.text || "unanswered GATE/ASK" });
      if (st === "HANDBACK" || st.indexOf("+HANDBACK") >= 0)
        hand.push({ fleet: it.fleet, kind: "handback", family: it.family, text: it.text || "awaiting demote + close" });
    }
    if (h.watcher && h.watcher.state !== "armed")
      watch.push({ fleet: String(h.name), kind: "watcher", family: "",
        text: String((h.watcher && h.watcher.detail) || "watcher down - fleet is blind") });
  }
  return pend.concat(hand, watch);
}

/**
 * Map the top-level `verify[]` array `ac-fleets.sh --json` emits (story
 * `verify-meta-namespace`, bin/ac-fleets.sh:139-172,355) into Processes rows.
 * The bucket token is the literal `'verify'` - no `verify-*` prefix matching
 * here, because the bash side (`ac_meta_is_verify`, bin/ac-lib.sh:777-784)
 * already decided what a verifier is; this is the one place that reads its
 * answer off the wire, so the expand key (`row.kind+':'+row.id`, unchanged)
 * comes out `verify:<id>`. `work` shows the entry's own meta kind (e.g.
 * "verify-review"), never the bucket. A verifier has no backlog row, but it
 * does hold a short-lived exact-ref lease and belongs to its supervising
 * family. The wire exposes caller/family/ref/worktree for monitoring; it does
 * not expose a lease timestamp, so `age` stays empty. Downstream code that keys
 * off `row.kind==='crew'` still withholds crew-only backlog/report links. Pure,
 * and deliberately ES5-plain like groupArtifacts - PAGE interpolates its
 * toString(), so the bucket the bun test proves is byte-the-same code the
 * browser runs.
 */
export function verifyProcessRows(verify: { id: string; kind?: string; project?: string; status?: string; caller?: string; family?: string; ref?: string; worktree?: string }[] | null | undefined): any[] {
  var out = [];
  var list = verify || [];
  for (var i = 0; i < list.length; i++) {
    var v = list[i];
    out.push({
      kind: "verify",
      id: v.id,
      work: v.kind || "verify",
      project: v.project || "—",
      state: v.status || "",
      live: true,
      age: "",
      ageVal: -1,
      room: v.family || null,
      caller: v.caller || "",
      ref: v.ref || "",
      worktree: v.worktree || "",
    });
  }
  return out;
}

export interface ArtifactNode {
  name: string; // this dir's own segment
  key: string; // the full path prefix down to it ("shp/review-r2")
  dirs: ArtifactNode[]; // sub-dirs, newest-first by the newest mtime they contain
  files: { name: string; art: any }[]; // leaves, newest-first
  mtime: number; // newest mtime anywhere in this subtree
  count: number; // leaves in this subtree
}

/**
 * Group the artifact list into the Reports folder tree: one level per segment
 * of `id`, files as leaves. Pure, and deliberately ES5-plain with no template
 * literal or backslash - it is ALSO injected verbatim into the client (PAGE
 * interpolates its toString()), so the tree the bun test proves is byte-the-same
 * code the browser runs.
 *
 * Grouping is by the id PATH, nothing else: `<family>/<sub-dirs>/<file>` nests
 * under the family, and a pooled `lavish/<task>/<file>` nests under a top-level
 * `lavish` node - honest (that is where it lives), no special case, no crash.
 * No "home" level: the Reports route is already scoped to one home.
 * Ordering is recomputed here, never inherited from the input order: files
 * newest-first by mtime, a dir by the newest mtime it contains.
 */
export function groupArtifacts(list: { id: string; mtime: number }[]): ArtifactNode {
  var root: ArtifactNode = { name: "", key: "", dirs: [], files: [], mtime: 0, count: 0 };
  for (var i = 0; i < list.length; i++) {
    var a = list[i];
    var raw = String(a && a.id != null ? a.id : "").split("/");
    var segs = [];
    for (var s = 0; s < raw.length; s++) { if (raw[s]) segs.push(raw[s]); }
    if (!segs.length) continue;
    var base = segs.pop();
    var node = root, prefix = "";
    for (var d = 0; d < segs.length; d++) {
      prefix = prefix ? prefix + "/" + segs[d] : segs[d];
      var next = null;
      for (var k = 0; k < node.dirs.length; k++) { if (node.dirs[k].name === segs[d]) { next = node.dirs[k]; break; } }
      if (!next) { next = { name: segs[d], key: prefix, dirs: [], files: [], mtime: 0, count: 0 }; node.dirs.push(next); }
      node = next;
    }
    node.files.push({ name: base, art: a });
  }
  var roll = function (n) {
    var mt = 0, cnt = n.files.length, x;
    for (x = 0; x < n.files.length; x++) { if (n.files[x].art.mtime > mt) mt = n.files[x].art.mtime; }
    for (x = 0; x < n.dirs.length; x++) {
      roll(n.dirs[x]);
      if (n.dirs[x].mtime > mt) mt = n.dirs[x].mtime;
      cnt += n.dirs[x].count;
    }
    n.mtime = mt; n.count = cnt;
    n.files.sort(function (p, q) { return q.art.mtime - p.art.mtime; });
    n.dirs.sort(function (p, q) { return q.mtime - p.mtime; });
  };
  roll(root);
  return root;
}

/**
 * Inline markdown on ALREADY-escaped text: inline code, links (safe schemes
 * only), bold, italic. Code spans are stashed first so their content is never
 * re-formatted; links are stashed before bold/italic so a URL is never mangled.
 * Underscore emphasis is boundary-guarded so snake_case identifiers survive.
 */
function inlineMd(escaped: string): string {
  const stash: string[] = [];
  const keep = (html: string): string => {
    stash.push(html);
    return "\u0000" + (stash.length - 1) + "\u0000";
  };
  let s = escaped;
  s = s.replace(/`([^`]+)`/g, (_m, c) => keep("<code>" + c + "</code>"));
  s = s.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_m, text, url) =>
    /^(https?:\/\/|mailto:|\/|\.|#)/i.test(url)
      ? keep('<a href="' + url + '" rel="noopener">' + text + "</a>")
      : text,
  );
  s = s.replace(
    /\*\*(\S(?:.*?\S)?)\*\*/g,
    (_m, t) => "<strong>" + t + "</strong>",
  );
  s = s.replace(
    /(^|[^A-Za-z0-9_])__(\S(?:.*?\S)?)__(?![A-Za-z0-9_])/g,
    (_m, pre, t) => pre + "<strong>" + t + "</strong>",
  );
  s = s.replace(/\*(\S(?:.*?\S)?)\*/g, (_m, t) => "<em>" + t + "</em>");
  s = s.replace(
    /(^|[^A-Za-z0-9_])_(\S(?:.*?\S)?)_(?![A-Za-z0-9_])/g,
    (_m, pre, t) => pre + "<em>" + t + "</em>",
  );
  // Restore stashed spans (loop-bounded: a link may contain a code placeholder).
  for (let g = 0; g <= stash.length && s.indexOf("\u0000") >= 0; g++) {
    s = s.replace(/\u0000(\d+)\u0000/g, (_m, i) => stash[Number(i)] ?? "");
  }
  return s;
}

/**
 * Render the common markdown subset the reports use to XSS-safe HTML, with NO
 * dependency: headings, paragraphs (single newline -> hard <br>), unordered and
 * ordered lists, GFM pipe tables, fenced/inline code, links, bold/italic. All text is escaped
 * first, then a fixed tag set is emitted - source HTML can never become a live
 * tag. Exported pure (like parseBacklog) so dash-records can reuse it.
 */
export function renderMarkdown(md: string, srcline = false): string {
  const lines = md.replace(/\r\n?/g, "\n").split("\n");
  const html: string[] = [];
  let para: string[] = [];
  let paraStart = 0;
  // srcline: stamp each block with its 1-based SOURCE line (data-srcline) so
  // a review pin on the rendered markdown maps back to the .md line the
  // agent edits - file:line is the language the fleet already speaks. Off by
  // default: previews and tests keep byte-identical output.
  const at = (n: number) => (srcline ? ' data-srcline="' + n + '"' : "");
  const flushPara = () => {
    if (para.length) {
      html.push(
        "<p" + at(paraStart) + ">" + para.map((l) => inlineMd(escapeHtml(l))).join("<br>") + "</p>",
      );
      para = [];
    }
  };
  const isItem = (l: string) => /^\s*([-*+]|\d+\.)\s+/.test(l);
  // GFM pipe table: split on |, dropping the empty edges the optional edge pipes
  // produce. A separator row (cells of -/: only) under a piped line is what turns
  // the block into a table - a piped paragraph without one stays a paragraph.
  const tcells = (l: string) =>
    l
      .trim()
      .replace(/^\|/, "")
      .replace(/\|$/, "")
      .split("|")
      .map((c) => c.trim());
  const tAlign = (l: string): (string | null)[] | null => {
    if (!l || !l.includes("|")) return null;
    const cs = tcells(l);
    if (!cs.length || !cs.every((c) => /^:?-+:?$/.test(c))) return null;
    return cs.map((c) =>
      c.startsWith(":") && c.endsWith(":")
        ? "center"
        : c.endsWith(":")
          ? "right"
          : c.startsWith(":")
            ? "left"
            : null,
    );
  };
  let i = 0;
  while (i < lines.length) {
    const line = lines[i];
    if (/^\s*```/.test(line)) {
      flushPara();
      const start = i + 1;
      // The fence info string becomes a language-<info> class - the same
      // convention the artifact pipeline already keys on (mermaid cards,
      // syntax-aware consumers); absent info emits the bare <code> as before.
      const info = (line.match(/^\s*```\s*(\S*)/) ?? [])[1] ?? "";
      const cls = info ? ' class="language-' + escapeHtml(info) + '"' : "";
      const body: string[] = [];
      i++;
      while (i < lines.length && !/^\s*```\s*$/.test(lines[i]))
        body.push(lines[i++]);
      if (i < lines.length) i++; // consume the closing fence
      html.push("<pre" + at(start) + "><code" + cls + ">" + escapeHtml(body.join("\n")) + "</code></pre>");
      continue;
    }
    const h = line.match(/^(#{1,6})\s+(.*)$/);
    if (h) {
      flushPara();
      const lv = h[1].length;
      html.push(
        "<h" + lv + at(i + 1) + ">" + inlineMd(escapeHtml(h[2].trim())) + "</h" + lv + ">",
      );
      i++;
      continue;
    }
    if (!line.trim()) {
      flushPara();
      i++;
      continue;
    }
    if (line.includes("|")) {
      const align = tAlign(lines[i + 1]);
      if (align) {
        flushPara();
        const tStart = i + 1;
        const head = tcells(line);
        const cell = (c: string, tag: string, n: number) =>
          "<" +
          tag +
          (align[n] ? ' style="text-align:' + align[n] + '"' : "") +
          ">" +
          inlineMd(escapeHtml(c)) +
          "</" +
          tag +
          ">";
        // Ragged rows pad/truncate to the header's width - deterministic, never a throw.
        const row = (cs: string[], tag: string) =>
          "<tr>" +
          head.map((_, n) => cell(cs[n] ?? "", tag, n)).join("") +
          "</tr>";
        let body = "";
        i += 2;
        while (i < lines.length && lines[i].trim() && lines[i].includes("|"))
          body += row(tcells(lines[i++]), "td");
        html.push(
          '<div class="tablewrap"' + at(tStart) + "><table><thead>" +
            row(head, "th") +
            "</thead><tbody>" +
            body +
            "</tbody></table></div>",
        );
        continue;
      }
    }
    if (isItem(line)) {
      flushPara();
      const ordered = /^\s*\d+\.\s+/.test(line);
      const items: string[] = [];
      // The run ends the moment the marker kind changes - "- a" and "1. b"
      // are two sibling lists, not one absorbing the other's stripped marker.
      while (i < lines.length && isItem(lines[i]) && /^\s*\d+\.\s+/.test(lines[i]) === ordered) {
        const itemStart = i + 1;
        const parts = [inlineMd(escapeHtml(lines[i].replace(/^\s*([-*+]|\d+\.)\s+/, "")))];
        i++;
        // CommonMark lazy continuation: a hard-wrapped line - indented to the
        // content column or not indented at all - keeps extending the same
        // item's paragraph instead of starting a sibling <p>. It stops at a
        // blank line or a real block start (item, heading, fence, GFM table
        // head) so it never swallows the next block; joined with <br> like
        // the paragraph path (:1036) treats a source line break the same way
        // inside a list as outside one.
        while (
          i < lines.length &&
          lines[i].trim() &&
          !isItem(lines[i]) &&
          !/^\s*```/.test(lines[i]) &&
          !/^#{1,6}\s+/.test(lines[i]) &&
          !(lines[i].includes("|") && tAlign(lines[i + 1]))
        ) {
          parts.push(inlineMd(escapeHtml(lines[i].trim())));
          i++;
        }
        items.push("<li" + at(itemStart) + ">" + parts.join("<br>") + "</li>");
      }
      html.push(
        (ordered ? "<ol>" : "<ul>") +
          items.join("") +
          (ordered ? "</ol>" : "</ul>"),
      );
      continue;
    }
    if (!para.length) paraStart = i + 1;
    para.push(line);
    i++;
  }
  flushPara();
  return html.join("\n");
}

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

/** Every crewdomain package's own backlog.md under a home - the same unquoted
 *  glob ac_domain_tally itself walks (bin/ac-lib.sh:625), ghost packages
 *  included, so this list's denominator matches the tally's. */
function domainBacklogFiles(homePath: string): { name: string; file: string }[] {
  const dir = `${homePath}/crewdomains`;
  let names: string[];
  try {
    names = readdirSync(dir);
  } catch {
    return [];
  }
  const out: { name: string; file: string }[] = [];
  for (const name of names) {
    const file = `${dir}/${name}/records/backlog.md`;
    if (existsSync(file)) out.push({ name, file });
  }
  return out;
}

/** Tag a backlog line with its crewdomain source, unless it already carries
 *  one (defensive - a domain's own backlog line should never carry the marker
 *  itself). */
function tagDomainLine(line: string, name: string): string {
  return line.includes("(domain:") ? line : `${line} (domain:${name})`;
}

/** Merge every crewdomain package's own backlog.md into `bl`'s three
 *  sections, each line tagged with its source (dash-domain-records surface
 *  c) - closes the blind spot where a row assigned into a domain leaves the
 *  fleet ledger and disappears from the UI entirely. Reuses parseBacklog -
 *  no new backlog grammar. Pure given the strings it reads; `bl` itself is
 *  never mutated. */
export function withDomainBacklogs(homePath: string, bl: BacklogView): BacklogView {
  const out: BacklogView = { in_flight: [...bl.in_flight], queued: [...bl.queued], done: [...bl.done] };
  for (const { name, file } of domainBacklogFiles(homePath)) {
    let md: string;
    try {
      md = readFileSync(file, "utf8");
    } catch {
      continue;
    }
    const dbl = parseBacklog(md);
    for (const key of ["in_flight", "queued", "done"] as const) {
      for (const line of dbl[key]) out[key].push(tagDomainLine(line, name));
    }
  }
  return out;
}

export interface DomainTally {
  queued: number;
  inFlight: number;
  done: number;
}

/** ac_domain_tally (bin/ac-lib.sh:625), run for every VALID id in ONE sourced
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
  backlog: boolean;
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
        backlog: existsSync(`${pkg}/records/backlog.md`),
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

/** HTML-escape text (matches the page's client-side esc()). */
function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

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
}

/**
 * Worktree pool for a home (§2.4): each projects/<repo>/.crew/slots/<n>.meta,
 * joined to state/<task>.meta `worktree=`. The projects/<repo> entry may be a
 * SYMLINK out of the container (drydock/projects/agent-crew -> ~/Work/agent-crew),
 * so the real repo root is resolved before reading .crew/slots.
 */
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
      pools.push({
        repo,
        slot: f.replace(/\.meta$/, ""),
        state: leased ? "leased" : "available",
        task: leased && task ? task : null,
        holder: leased ? metaGet(meta, "holder") || null : null,
        leased_at: leased ? metaGet(meta, "leased_at") || null : null,
        worktree:
          leased && task
            ? metaGet(`${homePath}/state/${task}.meta`, "worktree") || null
            : null,
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
// One set again (captain ruling "codereview-agent / qa-agent / gate-agent
// apply pi vs cursor"): every registry harness is offerable on every knob;
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
    remote: readRemote(homePath),
    // The KNOWN-FAMILY set for this route's task links, and the reason it is
    // served here rather than derived client-side: `familyOfTaskId` strips a
    // stage suffix only when the base is a real family, so an INCOMPLETE set
    // silently links a crew row at its own task id. `roomOf` - the only
    // family-ish index this route already held - lists families with a
    // room.md, which is a SUBSET (a room opens on a family's first
    // captain-facing event), so it would have broken more links than the
    // unconditional strip it replaced.
    families: backlogFamilyIds(
      withDomainBacklogs(
        homePath,
        existsSync(backlogFile)
          ? parseBacklog(readFileSync(backlogFile, "utf8"))
          : { in_flight: [], queued: [], done: [] },
      ),
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
  const own = existsSync(backlogFile)
    ? parseBacklog(readFileSync(backlogFile, "utf8"))
    : { in_flight: [], queued: [], done: [] };
  return json({ backlog: withDomainBacklogs(homePath, own) });
}

/** Reports route (§7.4): the discovered artifact master list (viewer bodies load
 *  lazily via /api/artifact on selection - the list is the only polled island). */
async function reportsDetail(homePath: string, limit = 0): Promise<Response> {
  if (!(await allowedHomePaths()).has(homePath))
    return json({ error: "unknown home" }, 404);
  // Paging BY FOLDER (captain orders 2026-08-01): the unit is the family
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
  return (CHIEF_KEYS as readonly string[]).includes(k);
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
// xterm.js (served at /assets/xterm/, provenance in bin/dashboard-assets/)
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

/** Vendored terminal renderer (bin/dashboard-assets/xterm/, provenance in its
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
  return new Response(Bun.file(import.meta.dir + "/dashboard-assets/xterm/" + name), {
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
// redraw-in-place left misaligned residue (the captain's "lỗi font" report).
const term = new Terminal({
  fontSize: 12, scrollback: 5000, theme: { background: "#0c252d" },
  fontFamily: "'JetBrains Mono', Menlo, Monaco, 'SF Mono', 'DejaVu Sans Mono', monospace",
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
  ws = new WebSocket("ws://" + location.host + "/api/term/ws?path=" + encodeURIComponent(path)
    + "&cols=" + term.cols + "&rows=" + term.rows);
  ws.binaryType = "arraybuffer";
  ws.onmessage = (e) => { if (g !== gen) return; term.write(typeof e.data === "string" ? e.data : new Uint8Array(e.data)); };
  ws.onclose = (e) => {
    if (g !== gen) return;
    term.write("\\r\\n\\x1b[33m[" + (e.reason || "disconnected") + " - reconnecting…]\\x1b[0m\\r\\n");
    setTimeout(() => { if (g === gen) { term.reset(); connect(); } }, 1200);
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
// Ask for it now rather than waiting for the parent's next poll render - the
// frame knows when it is ready, the parent does not.
try { if (parent !== window && typeof parent.termTheme === "function") parent.termTheme(); } catch { /* no parent - opened directly */ }
connect();
</script></body></html>`;
  return new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } });
}

/** The terminal theme push, shared VERBATIM by the SPA terminal tab and the
 * standalone /term page (both interpolate this function into their scripts -
 * the redrawMessage precedent): resolve --term-bg/--term-fg (falling back to
 * the page canvas pair) plus the 16 --ansi-N slots from computed styles into
 * an xterm theme object and a dedupe signature. Pure. */
export function termThemeCore(cs: { getPropertyValue(p: string): string }): { theme: Record<string, string>; sig: string } | null {
  var XT = ["black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
    "brightBlack", "brightRed", "brightGreen", "brightYellow", "brightBlue", "brightMagenta", "brightCyan", "brightWhite"];
  var bg = ((cs.getPropertyValue("--term-bg") || cs.getPropertyValue("--canvas")) || "").trim();
  var fg = ((cs.getPropertyValue("--term-fg") || cs.getPropertyValue("--fg")) || "").trim();
  if (!bg) return null;
  var t: Record<string, string> = { background: bg, foreground: fg, cursor: fg, cursorAccent: bg };
  var sig = bg + "|" + fg;
  for (var i = 0; i < 16; i++) {
    var c = (cs.getPropertyValue("--ansi-" + i) || "").trim();
    if (c) { t[XT[i]] = c; sig += "|" + c; }
  }
  return { theme: t, sig: sig };
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
  if (watchId) {
    // Linked terminals: watch a crewmate/verify pane OF THIS FAMILY,
    // read-only. Membership is re-derived here from state/ metas - the id the
    // client sent only counts if this family really owns it.
    if (family === "" || !/^[a-zA-Z0-9_.-]+$/.test(watchId))
      return json({ error: "bad watch id" }, 400);
    let metas: { id: string; text: string }[] = [];
    try {
      metas = readdirSync(`${homePath}/state`).filter((f) => f.endsWith(".meta"))
        .map((f) => { try { return { id: f.slice(0, -5), text: readFileSync(`${homePath}/state/${f}`, "utf8") }; } catch { return null; } })
        .filter((x): x is { id: string; text: string } => !!x);
    } catch { /* no state dir */ }
    const member = familyPaneIds(metas, family).find((x) => x.id === watchId);
    if (!member) return json({ live: false, why: "not a pane of this family" });
    const meta = metas.find((x) => x.id === watchId);
    const h = paneHandleByMeta(homePath, watchId, meta ? meta.text : "");
    if (!h) return json({ live: false, why: "pane handle unresolvable" });
    const r = await run(
      ["herdr", "pane", "read", h.pane, "--source", "recent-unwrapped", "--format", "ansi", "--lines", String(Math.max(lines, 200))],
      { AC_HOME: homePath },
    );
    if (r.code !== 0) return json({ live: false, why: "pane unreadable (backend down or pane gone)" });
    return json({ live: true, pane: h.pane, readonly: true, html: ansiToHtml(r.out.split("\n").slice(-lines).join("\n")) });
  }
  if (family === "") {
    // Crewchief target (slice C): resolved via the session lock, not a meta.
    const h = await fleetChiefHandle(homePath);
    if (!h) return json({ live: false, why: "no live crewchief session" });
    const r = await run(
      ["herdr", "pane", "read", h.pane, "--source", "recent-unwrapped", "--format", "ansi", "--lines", String(Math.max(lines, 200))],
      { AC_HOME: homePath },
    );
    if (r.code !== 0) return json({ live: false, why: "pane unreadable (backend down or pane gone)" });
    return json({ live: true, pane: h.pane, html: ansiToHtml(r.out.split("\n").slice(-lines).join("\n")) });
  }
  let metaText = "";
  try {
    metaText = readFileSync(`${homePath}/state/${family}-chief.meta`, "utf8");
  } catch {
    return json({ live: false, why: "no roomchief for this family" });
  }
  let pane = chiefPaneOf(metaText);
  if (!pane) return json({ live: false, why: "chief meta carries no readable pane" });
  // The handle FILE is what the backend itself reads (backend_capture): panes
  // can be re-created after spawn, so its first token outranks the meta echo.
  try {
    const tok = readFileSync(`${homePath}/state/.pane-${family}-chief`, "utf8").trim().split(/\s+/)[0];
    if (tok && /^[A-Za-z0-9]+:[A-Za-z0-9]+$/.test(tok)) pane = tok;
  } catch { /* no handle file - keep the meta-derived pane */ }
  const { code, out } = await run(
    ["herdr", "pane", "read", pane, "--source", "recent-unwrapped", "--format", "ansi", "--lines", String(Math.max(lines, 200))],
    { AC_HOME: homePath },
  );
  if (code !== 0) return json({ live: false, why: "pane unreadable (backend down or pane gone)" });
  const tail = out.split("\n").slice(-lines).join("\n");
  return json({ live: true, pane, html: ansiToHtml(tail) });
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
): { id: string; family: string; repo: string; pr: string; prMerged: boolean }[] {
  const out: { id: string; family: string; repo: string; pr: string; prMerged: boolean }[] = [];
  const take = (id: string, text: string) => {
    const family = metaValue(text, "fleet_scope") || taskFamilyOf(id, known);
    if (families.indexOf(family) < 0) return;
    const kind = metaValue(text, "kind");
    const repo = kind === "roomchief" || kind === "crewdeputy" ? "" : metaValue(text, "project");
    const pr = metaValue(text, "pr");
    if (!repo && !pr) return;
    out.push({ id, family, repo, pr, prMerged: metaValue(text, "pr_merged") === "1" });
  };
  const read = (file: string, id: string) => {
    try {
      take(id, readFileSync(file, "utf8"));
    } catch { /* unreadable meta - the task simply contributes nothing */ }
  };
  try {
    for (const f of readdirSync(`${homePath}/state`))
      if (f.endsWith(".meta")) read(`${homePath}/state/${f}`, f.slice(0, -5));
  } catch { /* no state dir */ }
  // ac-teardown.sh relocates a finished task's state to state/archive/<id>/ -
  // where a LANDED family's PRs live, since the meta is archived at teardown.
  try {
    for (const d of readdirSync(`${homePath}/state/archive`))
      read(`${homePath}/state/archive/${d}/meta`, d);
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
  const artifacts = collectArtifacts(homePath);
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
  const timelineFile = `${familyDataDir(homePath, family)}/timeline.log`;
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
  // <home>/whiteboards/ - a captain-facing store of its own (captain order
  // 2026-08-01), NOT under data/: scenes are not task artifacts, and under
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
  const binDir = new URL(".", import.meta.url).pathname;
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
  const binDir = new URL(".", import.meta.url).pathname;
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
// REVIEW SHARE (the authoritative contract; captain ruling): the
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
  // yanks the top window away - full-tab only (captain 2026-08-18).
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
  // Mermaid pass for md artifacts: the rendered
  // markdown ships fences as escaped code with no script of its own, so the
  // Diagram view read as source text. Render the SVG INSIDE the existing
  // element - the one the card wrapped, the switch toggles, the pin
  // anchors, and data-srcline rides on - so nothing else moves.
  // class=mermaid blocks get the same treatment ONLY when the artifact ships
  // no mermaid of its own (script sniff below; data-acrv marks this overlay
  // so it never counts as the artifact's) - a self-rendering artifact keeps
  // its own theme/config, and data-processed guards the race both ways.
  // Returns a promise that resolves once every matched diagram has actually
  // rendered (or immediately when there is nothing to render) - never
  // rejects, so a CDN failure still resolves and never blocks a caller
  // waiting on it (dash-review-polish-scroll r1: boot() awaits this before
  // signaling ready, since an SVG replacing a <pre> placeholder changes
  // layout height and firing ready any earlier restores scroll into a
  // document whose layout has not settled yet).
  function mermaidPass(){
    const fences = document.querySelectorAll("pre > code[class*=language-mermaid]");
    const foreign = Array.prototype.some.call(document.querySelectorAll("script"), (s) =>
      !s.hasAttribute("data-acrv") && ((s.src || "").indexOf("mermaid") >= 0 || (s.textContent || "").indexOf("mermaid") >= 0));
    const blocks = foreign ? [] : Array.prototype.filter.call(
      document.querySelectorAll("pre.mermaid, div.mermaid"),
      (el) => !el.querySelector("svg") && !el.getAttribute("data-processed"));
    if (!fences.length && !blocks.length) return Promise.resolve();
    return import("https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs").then((m) => {
      const mm = m.default;
      mm.initialize({ startOnLoad: false, theme: "neutral" });
      const draw = (el, src, i) => {
        if (el.getAttribute("data-mmd")) return Promise.resolve();
        el.setAttribute("data-mmd", "1");
        return mm.render("rvmmd" + i, src).then((r) => {
          el.innerHTML = r.svg;
          el.setAttribute("data-processed", "true");
          el.style.cssText = "background:#fff;border:0;margin:0;padding:10px;overflow-x:auto";
        }).catch(() => { el.setAttribute("data-mmd", "err"); });
      };
      const draws = [];
      fences.forEach((code, i) => { const pre = code.closest("pre"); if (pre) draws.push(draw(pre, code.textContent, i)); });
      blocks.forEach((el, i) => draws.push(draw(el, el.textContent, fences.length + i)));
      return Promise.all(draws);
    }).catch(() => {});
  }
  function boot(){
    tagDiagrams();
    // Scroll-restore readiness (dash-review-polish-scroll defect 2, r1 fix):
    // fires only once mermaidPass()'s own layout-affecting async work has
    // actually settled, so the review page never restores a scroll position
    // into a document whose diagrams have not finished rendering yet.
    mermaidPass().then(() => {
      parent.postMessage({ lavishNative: true, ready: true }, "*");
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
    // The anchor's HUMAN face (captain 2026-08-18): the element's own text
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

if (import.meta.main) {
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
        if (dk.kind === "pane") {
          const d = ws.data as { home: string; fam: string; watch: string; lines: number; last?: string; timer?: ReturnType<typeof setInterval> };
          const tick = async () => {
            try {
              const res = await roomPane(d.home, d.fam, d.watch, d.lines);
              const j = await res.json() as { live?: boolean; html?: string };
              const key = (j.live ? "1" : "0") + (j.html ?? "") + String(d.lines);
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
      },
      message(ws, data) {
        const dk = ws.data as { kind?: string };
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
        const d = ws.data as { term?: Bun.Terminal; proc?: ReturnType<typeof Bun.spawn> };
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
        if (ptyCount >= 4) return json({ error: "too many terminals (4 max)" }, 429);
        const size = termSize(url.searchParams.get("cols"), url.searchParams.get("rows"));
        if (server.upgrade(req, { data: { kind: "pty", ...size } })) return undefined as unknown as Response;
        return json({ error: "websocket required" }, 400);
      }
      if (url.pathname === "/api/room/stream") {
        // Chat-panel pane stream (captain ruling: native, ONE task pane,
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
      if (url.pathname === "/api/snapshot.json") return snapshot();
      if (url.pathname === "/api/brain") {
        const p = url.searchParams.get("path");
        return p ? brainStat(p) : json({ error: "path required" }, 400);
      }
      if (url.pathname === "/api/brain-recall") {
        const p = url.searchParams.get("path");
        const q = url.searchParams.get("q") ?? "";
        if (!p) return json({ error: "path required" }, 400);
        const argv = [process.execPath, BIN + "/ac-brain-engine.ts", "recall", "--home", p, "--limit", "10", "--compact"];
        if (q) argv.push("--query", q);
        const proc = Bun.spawnSync(argv, { timeout: 30000 });
        const text = new TextDecoder().decode(proc.stdout).trim();
        try { return json(JSON.parse(text)); } catch { return json({ error: "engine", detail: text.slice(0, 300) }, 500); }
      }
      if (url.pathname === "/api/brain-synthesize") {
        const p = url.searchParams.get("path");
        const q = url.searchParams.get("q") ?? "";
        if (!p || !q) return json({ error: "path and q required" }, 400);
        const proc = Bun.spawnSync([process.execPath, BIN + "/ac-brain-engine.ts", "synthesize", q, "--home", p, "--compact"], { timeout: 180000 });
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

// ---------------------------------------------------------------------------
// The SPA shell: inline <style> + inline vanilla JS. No framework, no CDN, no
// build, no external asset - the only reachable thing is the localhost bind.
// The client JS avoids template literals AND backslash-bearing regex literals so
// this outer template literal needs no escaping (a `\` before a non-escape char
// would be swallowed by the template literal, so the router parses paths by
// String.split, never by regex).
// ---------------------------------------------------------------------------

const PAGE = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>agent-crew dashboard</title>
<link rel="icon" href="data:,">
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Ctext y='13' font-size='13'%3E%E2%9A%93%3C/text%3E%3C/svg%3E">
${THEME_INIT}
<style>
${THEME_VARS}
${UX_BASE}
  :root{
    --focus:var(--accent);
    /* Layout + derived aliases (theme-neutral): the palette itself lives in
       THEME_VARS above, so the Board/detail view - which consumes ONLY these
       tokens, no hardcoded hex - reskins for free in either theme. */
    --bg:var(--canvas); --panel:var(--surface); --panel-2:var(--elev);
    --ink:var(--fg); --muted:var(--fg2); --line:var(--border);
    --good:var(--success); --warn:var(--warning); --bad:var(--error);
    --purple:var(--stale);
    --bad-soft:color-mix(in srgb, var(--bad) 16%, transparent);
    --purple-soft:color-mix(in srgb, var(--purple) 18%, transparent);
    --scrim:rgba(0,0,0,.5); --shadow-pop:0 24px 70px rgba(0,0,0,.5); --shadow-card:0 2px 10px rgba(0,0,0,.18);
    --ui: ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    --sb:224px;
    /* The page gutter, as vars so a full-bleed page can cancel it exactly
       instead of hard-coding the same two numbers a second time. */
    --pagepad-y:16px; --pagepad-x:20px;
  }
  *{ box-sizing:border-box; }
  html,body{ height:100%; }
  body{ margin:0; background:var(--canvas); color:var(--fg); font:14px/1.5 var(--ui); }
  /* Wallpaper layer (dash-bg): a fixed image painted between the canvas color
     and the content (negative z-index child sits above the parent's own
     background). Opacity = (100-dim)% so dimming fades toward the theme. */
  body::before{ content:""; position:fixed; inset:0; z-index:-1; pointer-events:none;
    background-image:var(--bg-img, none); background-size:cover; background-position:center;
    opacity:var(--bg-img-op, 0); }
  .mono{ font-family:var(--mono); }
  a{ color:var(--accent); text-decoration:none; cursor:pointer; }
  a:hover, a:focus-visible{ text-decoration:underline; }
  :focus-visible{ outline:2px solid var(--focus); outline-offset:2px; }
  button{ font:inherit; color:var(--fg); cursor:pointer; background:none; border:none; }
  h1,h2,h3,h4{ margin:0; }
  ul{ margin:0; }

  /* ---- shell ---- */
  .shell{ display:flex; min-height:100vh; }
  .sidebar{ width:var(--sb); flex:0 0 var(--sb); background:var(--surface); border-right:1px solid var(--border);
    display:flex; flex-direction:column; padding:12px 8px; gap:6px; position:sticky; top:0; height:100vh; overflow:auto; }
  body.sb-collapsed .sidebar{ width:56px; flex-basis:56px; }
  body.sb-collapsed .lbl, body.sb-collapsed .brandtext, body.sb-collapsed .navcap,
  body.sb-collapsed .selname, body.sb-collapsed .fleetlist, body.sb-collapsed .pagenav,
  body.sb-collapsed .sys, body.sb-collapsed .clbl{ display:none; }
  .brand{ display:flex; align-items:center; gap:8px; color:var(--accent); font-weight:700; letter-spacing:.04em; padding:4px 8px; }
  .brand .anchor{ font-size:16px; }
  .navsec{ display:flex; flex-direction:column; gap:2px; }
  .navcap{ color:var(--fg2); font-size:11px; text-transform:uppercase; letter-spacing:.05em; padding:8px 8px 2px; }
  .navitem{ display:flex; align-items:center; gap:10px; padding:7px 8px; border-radius:4px; color:var(--fg2); font-size:13px; }
  .navitem:hover{ background:var(--elev); text-decoration:none; }
  .navitem[aria-current="page"]{ color:var(--accent); background:var(--accent-soft); border-radius:6px; font-weight:600; }
  .navitem .ico{ width:16px; text-align:center; }
  .fleetlist, .pagenav{ list-style:none; margin:2px 0; padding:0; display:flex; flex-direction:column; gap:1px; }
  .fleetlist a, .pagenav a{ display:flex; align-items:center; gap:8px; padding:5px 8px 5px 26px; border-radius:4px; color:var(--fg2); font-size:13px; }
  .fleetlist a:hover, .pagenav a:hover{ background:var(--elev); text-decoration:none; }
  .fleetlist a[aria-current="page"], .pagenav a[aria-current="page"]{ color:var(--accent); background:var(--accent-soft); border-radius:6px; font-weight:600; }
  .fleetlist .st{ font-size:9px; }
  .fleetlist .fn{ font-family:var(--mono); }
  .fleetlist li.dep a{ padding-left:42px; position:relative; }
  .fleetlist li.dep a::before{ content:"\\21B3"; position:absolute; left:26px; top:50%; transform:translateY(-50%); color:var(--fg2); font-size:11px; line-height:1; }
  .pagenav a[aria-disabled="true"]{ opacity:.4; pointer-events:none; }
  /* Group captions must READ as captions (menu-redesign follow-up): a divider
     above, less indent than the items they head, dimmer + spaced apart. */
  .pagenav .navgap{ color:var(--fg2); opacity:.75; font-size:10px; font-weight:700; text-transform:uppercase;
    letter-spacing:.09em; padding:9px 8px 3px 12px; margin-top:6px; border-top:1px solid var(--border); }
  .pagenav li:first-child.navgap{ border-top:0; margin-top:0; }
  .selname{ padding:0 8px 4px; color:var(--fg); font-size:13px; }
  .navspacer{ flex:1 1 auto; }
  .sys{ border-top:1px solid var(--border); padding:8px; font-size:12px; color:var(--fg2); display:flex; flex-direction:column; gap:3px; }
  .sys .n{ color:var(--fg); font-family:var(--mono); }
  .sys .w{ color:var(--warning); } .sys .e{ color:var(--error); }
  .collapse{ background:var(--elev); border:1px solid var(--border); border-radius:4px; padding:6px; color:var(--fg2); display:flex; align-items:center; gap:8px; justify-content:center; }
  .collapse:hover{ border-color:var(--border-strong); }

  /* ---- main ---- */
  .main{ flex:1 1 auto; min-width:0; display:flex; flex-direction:column; }
  .pagehead{ position:sticky; top:0; z-index:5; background:color-mix(in srgb, var(--surface) 86%, transparent); backdrop-filter:blur(8px); -webkit-backdrop-filter:blur(8px); border-bottom:1px solid var(--border);
    padding:12px 20px; display:flex; align-items:center; gap:16px; flex-wrap:wrap; }
  .headline{ display:flex; align-items:baseline; gap:14px; flex-wrap:wrap; min-width:0; }
  .pagehead h1{ font-size:22px; font-weight:600; }
  .pagehead .meta{ color:var(--fg2); font-size:13px; display:flex; gap:14px; flex-wrap:wrap; }
  .pagehead .crumb{ color:var(--fg2); font-size:13px; }
  .pagehead .crumb b{ color:var(--fg); font-weight:600; }
  .actions{ margin-left:auto; display:flex; align-items:center; gap:12px; }
  .live{ display:flex; align-items:center; gap:6px; font-size:12px; color:var(--fg2); }
  .live .dot{ width:8px; height:8px; border-radius:50%; background:var(--fg2); flex:0 0 auto; }
  .live.s-live .dot{ background:var(--success); }
  .live.s-refresh .dot{ background:var(--warning); animation:pulse 1s ease-in-out infinite; }
  .live.s-stale .dot{ background:var(--stale); }
  .live.s-down .dot{ background:var(--error); }
  @keyframes pulse{ 0%,100%{ opacity:1; } 50%{ opacity:.35; } }
  @media (prefers-reduced-motion: reduce){ .live .dot{ animation:none !important; } }
  .btn{ background:var(--elev); border:1px solid var(--border); border-radius:4px; padding:5px 10px; color:var(--fg); font-size:13px; }
  .btn:hover{ border-color:var(--border-strong); }
  .btn.sm{ padding:2px 9px; font-size:12px; }
  .btn.primary{ background:var(--accent); color:var(--accent-ink); border-color:var(--accent); font-weight:600; }
  .btn.primary:hover{ filter:brightness(1.08); }
  .btn:disabled{ opacity:.5; cursor:not-allowed; }
  #theme-btn{ border-radius:20px; line-height:1; }
  .page{ padding:var(--pagepad-y) var(--pagepad-x); flex:1 1 auto; min-width:0; }

  /* ---- generic ---- */
  .card{ background:var(--surface); border:1px solid var(--border); border-radius:6px; padding:14px; }
  .muted{ color:var(--fg2); }
  .ts{ font-family:var(--mono); color:var(--fg2); font-size:12px; }
  .badge{ display:inline-flex; align-items:center; gap:4px; font-size:12px; padding:1px 8px; border-radius:10px; border:1px solid var(--border); color:var(--fg2); white-space:nowrap; }
  .badge.ok{ color:var(--success); border-color:var(--success); }
  .badge.warn{ color:var(--warning); border-color:var(--warning); }
  .badge.err{ color:var(--error); border-color:var(--error); }
  .badge.stale{ color:var(--stale); border-color:var(--stale); }
  .badge.accent{ color:var(--accent); border-color:var(--accent); }
  .dot-i{ display:inline-block; width:8px; height:8px; border-radius:50%; }
  .state{ padding:28px 20px; text-align:center; color:var(--fg2); }
  .state .st-title{ color:var(--fg); font-size:15px; margin-bottom:6px; }
  .state.err .st-title{ color:var(--error); }
  .skeleton{ display:flex; flex-direction:column; gap:10px; padding:6px; }
  .skeleton .sk{ height:34px; border-radius:6px; background:linear-gradient(90deg, var(--surface), var(--elev), var(--surface)); background-size:200% 100%; animation:sh 1.4s linear infinite; }
  @keyframes sh{ 0%{ background-position:200% 0; } 100%{ background-position:-200% 0; } }
  @media (prefers-reduced-motion: reduce){ .skeleton .sk{ animation:none; } }

  .filters{ display:flex; gap:6px; align-items:center; flex-wrap:wrap; }
  .chip{ background:var(--elev); border:1px solid var(--border); border-radius:4px; padding:3px 11px; font-size:12px; color:var(--fg2); }
  .chip:hover{ border-color:var(--border-strong); }
  .chip[aria-pressed="true"]{ color:var(--accent); border-color:var(--accent); }
  .search-in{ background:var(--elev); border:1px solid var(--border); border-radius:4px; padding:6px 11px; color:var(--fg); font:inherit; width:300px; max-width:100%; }
  .search-in:focus{ outline:2px solid var(--focus); outline-offset:1px; }

  .tblwrap{ overflow-x:auto; border:1px solid var(--border); border-radius:6px; background:var(--surface); }
  .tbl{ width:100%; border-collapse:collapse; font-size:13px; }
  .tbl th, .tbl td{ text-align:left; padding:7px 12px; border-bottom:1px solid var(--border); vertical-align:top; }
  .tbl tbody tr:last-child td{ border-bottom:none; }
  .tbl th{ color:var(--fg2); font-weight:500; font-size:12px; white-space:nowrap; }
  .tbl th button.sort{ color:var(--fg2); display:inline-flex; gap:5px; align-items:center; font-weight:500; }
  .tbl th button.sort:hover{ color:var(--fg); }
  .tbl th[aria-sort="ascending"] button.sort, .tbl th[aria-sort="descending"] button.sort{ color:var(--accent); }
  .tbl td.id{ font-family:var(--mono); color:var(--accent); }
  .tbl td.mono{ font-family:var(--mono); }
  .tbl tr.exp-open{ background:var(--elev); }
  .tbl tr.exp-row td{ background:var(--elev); }
  .rowdisc{ display:inline-flex; align-items:center; gap:6px; color:var(--fg); text-align:left; width:100%; }
  .rowdisc .caret{ color:var(--fg2); width:10px; display:inline-block; }
  .expbox{ padding:4px 0; }
  .expbox .lnk{ display:inline-flex; gap:12px; margin-top:6px; flex-wrap:wrap; }
  pre.room{ background:var(--canvas); border:1px solid var(--border); border-radius:6px; padding:10px 12px; margin:6px 0 0;
    white-space:pre-wrap; word-break:break-word; max-height:320px; overflow:auto; font-family:var(--mono); font-size:12px; line-height:1.5; }

  /* ---- Fleets ---- */
  .attn{ display:flex; gap:20px; flex-wrap:wrap; padding:12px 16px; margin-bottom:16px; background:var(--surface); border:1px solid var(--border); border-radius:6px; }
  .attn .item{ display:flex; gap:8px; align-items:center; font-size:14px; }
  .attn .num{ font-weight:700; font-size:16px; }
  .attn .a-warn .num{ color:var(--warning); } .attn .a-err .num{ color:var(--error); }
  .attn .a-ok .num{ color:var(--fg); } .attn .item .lbl2{ color:var(--fg2); }
  /* needs-captain queue under the strip (fleets-attn-queue) */
  /* material-icon-theme style tree icons (reports/records) */
  .fico{ display:inline-flex; width:15px; height:15px; flex:0 0 auto; align-items:center; justify-content:center; }
  .fico.m{ border-radius:3px; font:700 7.5px/15px var(--mono); text-align:center; letter-spacing:0; }
  .fico.dir svg{ width:14px; height:14px; }
  .attnq{ display:flex; flex-direction:column; gap:6px; margin-bottom:16px; }
  .attnq-it{ display:flex; align-items:center; gap:10px; padding:9px 12px; background:var(--surface);
    border:1px solid var(--border); border-radius:6px; color:var(--fg); min-width:0; }
  .attnq-it:hover{ border-color:var(--border-strong); text-decoration:none; }
  .attnq-it .fam{ font-weight:600; flex:0 0 auto; }
  .attnq-it .fl{ color:var(--fg2); font-size:11px; border:1px solid var(--border); border-radius:4px; padding:0 5px; flex:0 0 auto; }
  .attnq-it .tx{ color:var(--fg2); font-size:12px; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; min-width:0; }
  .grid{ display:grid; grid-template-columns:repeat(auto-fill, minmax(320px, 1fr)); gap:14px; }
  .fcard{ display:flex; flex-direction:column; gap:9px; }
  .fcard:hover{ border-color:var(--border-strong); }
  .fcard .top{ display:flex; align-items:center; justify-content:space-between; gap:8px; }
  .fcard .fname{ color:var(--accent); font-weight:700; font-size:15px; font-family:var(--mono); }
  .fcard .subline{ color:var(--fg2); font-size:12px; }
  .fcard .stats{ display:flex; gap:8px 16px; flex-wrap:wrap; font-size:13px; }
  .fcard .stats .kv b{ color:var(--fg); font-weight:600; }
  .fcard .stats .kv{ color:var(--fg2); }
  .fcard .attnrow{ display:flex; gap:8px; flex-wrap:wrap; }
  .fcard .cta{ margin-top:2px; font-size:13px; }
  .fcard.depcard{ margin-left:18px; box-shadow:inset 3px 0 0 var(--border-strong); }
  .cadence{ color:var(--fg2); }
  .cadence.due{ color:var(--warning); font-weight:600; }
  .fcard .cadence{ font-size:12px; }
  .deputy-tag{ font-size:11px; }

  /* ---- master-detail (Reports / Records) ---- */
  .md-layout{ display:grid; grid-template-columns:minmax(240px, 330px) 1fr; gap:14px; align-items:start; }
  .md-list{ background:var(--surface); border:1px solid var(--border); border-radius:6px; max-height:calc(100vh - 150px); overflow:auto; display:flex; flex-direction:column; }
  .md-list .ltools{ padding:10px; border-bottom:1px solid var(--border); display:flex; flex-direction:column; gap:8px; position:sticky; top:0; background:var(--surface); z-index:1; }
  .md-list .ltools .search-in{ width:100%; }
  .md-list .lbody{ padding:6px; }
  .arow{ display:flex; align-items:center; gap:8px; padding:6px 8px; border-radius:4px; color:var(--fg); width:100%; text-align:left; font-size:13px; }
  .wbtools{ display:flex; gap:8px; align-items:center; padding:10px 12px; border-bottom:1px solid var(--border); }
  .wbtools input, .wbrow input{ background:var(--canvas); color:var(--fg); border:1px solid var(--border); border-radius:5px; padding:5px 8px; font:13px var(--ui); width:200px; }
  .wbtools input:focus, .wbrow input:focus{ outline:none; border-color:var(--accent); }
  .wbrow{ display:flex; align-items:center; gap:10px; padding:9px 12px; border:1px solid var(--border); background:var(--elev); border-radius:6px; margin:8px 12px 0; }
  .rvdot{ width:8px; height:8px; border-radius:50%; background:var(--fg2); flex:0 0 auto; }
  .rvdot.ok{ background:var(--success); }
  .wbrow .nm{ color:var(--fg); font-weight:600; }
  .wbrow .ts{ color:var(--fg2); font-size:12px; flex:1; }
  .wbrow a.chip, .wbrow button.chip{ font-size:12px; }
  .wbrow button.danger{ color:var(--error); border-color:var(--error); }
  /* Above .bscrim (60): the Board detail modal is itself content toolOpen must
     layer over, exactly like it already layers over the Reports page - else a
     Review opened from inside the Board detail renders hidden behind it. */
  #toolview{ position:fixed; top:0; left:var(--sb); right:0; bottom:0; z-index:61; display:none; flex-direction:column; background:var(--canvas); border-left:1px solid var(--border-strong); }
  #toolview .tbar{ display:flex; align-items:center; gap:14px; padding:7px 14px; background:var(--surface); border-bottom:1px solid var(--border); }
  #toolview .tname{ font-weight:600; }
  #toolview .tbar a{ font-size:12px; }
  #toolview .tbar button{ margin-left:auto; font:inherit; color:var(--fg); background:var(--elev); border:1px solid var(--border); border-radius:5px; padding:4px 12px; cursor:pointer; }
  #toolview iframe{ flex:1; border:0; }
  .arow:hover{ background:var(--elev); }
  .arow[aria-current="true"]{ background:var(--elev); box-shadow:inset 2px 0 0 var(--accent); }
  .arow .aname{ font-family:var(--mono); flex:1 1 auto; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  /* Artifact rows are two-line: the stage (the discriminator between two rows of
     one family) gets a full-width line, family + badges sit under it. */
  .arow.arow2{ flex-direction:column; align-items:stretch; gap:2px; }
  .arow2 .astage{ font-family:var(--mono); font-weight:600; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .arow2 .ameta{ display:flex; align-items:center; gap:8px; font-size:12px; color:var(--fg2); }
  .arow2 .afam{ font-family:var(--mono); flex:1 1 auto; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  /* Folder tree (Reports): one row per node, indented by depth. The leaf name
     WRAPS rather than ellipsising - the column is 330px (280px under the
     breakpoint) and a cut tail hides exactly what tells two files apart. */
  .tnode{ display:flex; align-items:center; gap:6px; width:100%; text-align:left; color:var(--fg); font-size:13px; padding:5px 8px; border-radius:4px; }
  .tnode:hover{ background:var(--elev); }
  .tnode .caret{ color:var(--fg2); width:10px; flex:0 0 auto; }
  /* One line, never wrapped (captain 2026-08-18) - the full name rides the
     title tooltip on both folder and file rows. */
  .tnode .tname{ font-family:var(--mono); flex:1 1 auto; min-width:0; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .tnode .cnt{ color:var(--fg2); font-size:12px; }
  .tnoderow{ display:flex; align-items:center; } .tnoderow .tnode{ flex:1 1 auto; min-width:0; }
  .tlink{ flex:0 0 auto; color:var(--fg2); font-size:12px; padding:4px 8px; border-radius:4px; }
  .tlink:hover{ color:var(--accent); background:var(--elev); }
  .arow.atree{ align-items:center; gap:6px; }
  .arow.atree .aname{ overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .arow.atree .badge{ flex:0 0 auto; }
  /* Tree|Flat wraps as ONE unit (the 330px column never fits 5 chips on a line). */
  .filters .vsw{ display:inline-flex; gap:6px; margin-left:auto; }
  .viewer{ background:var(--elev); border:1px solid var(--border); border-radius:6px; height:calc(100vh - 150px); position:sticky; top:90px; display:flex; flex-direction:column; overflow:hidden; }
  .viewer .vhead{ padding:10px 16px; border-bottom:1px solid var(--border); display:flex; align-items:center; gap:12px; flex-wrap:wrap; background:var(--surface); }
  .viewer .vtitle{ font-weight:600; font-family:var(--mono); font-size:13px; }
  .viewer .vhead .vsp{ margin-left:auto; display:flex; align-items:center; gap:8px; }
  .viewer .vbody{ padding:18px 22px; overflow:auto; flex:1 1 auto; }
  .viewer .vbody.frameonly{ padding:0; }
  /* Reader typography + table rules (incl. .tablewrap{overflow-x:auto} - a wide
     table scrolls inside its own box, the page body never scrolls sideways):
     readerCss(".reader") is shared verbatim with the /review iframe's own
     unscoped copy (readerCss("")) - one authoritative rule set, not two. */
  ${readerCss(".reader")}
  iframe.frame{ width:100%; height:100%; min-height:calc(100vh - 210px); border:0; background:#fff; display:block; }
  /* Non-md/html previews: raw text keeps its columns (patches, json, logs);
     images fit the pane. */
  .filetext{ font-family:var(--mono); font-size:.85em; line-height:1.5; white-space:pre; overflow:auto; margin:0; color:var(--fg); }
  .imgview{ display:flex; align-items:flex-start; justify-content:center; background:var(--canvas); }
  .viewimg{ max-width:100%; height:auto; border:1px solid var(--border); border-radius:4px; }

  /* ---- Backlog ---- */
  .disc{ border:1px solid var(--border); border-radius:6px; margin-bottom:12px; background:var(--surface); overflow:hidden; }
  .disc > .dh{ width:100%; display:flex; align-items:center; gap:10px; padding:10px 14px; color:var(--fg); text-align:left; font-size:14px; }
  .disc > .dh:hover{ background:var(--elev); }
  .disc .caret{ color:var(--fg2); width:10px; }
  .disc .dh .cnt{ color:var(--fg2); font-size:12px; margin-left:2px; }
  .disc .dbody{ padding:2px 8px 8px; }
  .blrow{ padding:9px 12px 10px; border-top:1px solid var(--border); font-size:13px; }
  .blrow:hover{ background:var(--elev); }
  .blrow .blhead{ display:flex; align-items:center; gap:6px; flex-wrap:wrap; }
  .blrow .bid{ font-family:var(--mono); color:var(--accent); }
  .blrow .rmeta{ margin-left:auto; display:flex; align-items:center; gap:6px; }
  .blrow .btext{ display:block; margin-top:4px; color:var(--fg); line-height:1.5; }
  .blrow .btext.clip{ display:-webkit-box; -webkit-line-clamp:2; -webkit-box-orient:vertical; overflow:hidden; }
  .blrow .more{ font-size:12px; }

  /* ---- Search ---- */
  .searchpage{ max-width:900px; }
  .sresult{ padding:12px 14px; border:1px solid var(--border); border-radius:6px; margin-bottom:10px; background:var(--surface); }
  .sresult .rhead{ display:flex; gap:10px; align-items:center; flex-wrap:wrap; }
  .sresult .rfleet{ color:var(--accent); font-family:var(--mono); font-weight:600; }
  .sresult .rline{ color:var(--fg); font-size:13px; margin:6px 0; font-family:var(--mono); }
  .sresult .rline.clip{ max-height:7.6em; overflow:hidden; -webkit-mask-image:linear-gradient(#000 70%, transparent); mask-image:linear-gradient(#000 70%, transparent); }
  .sresult .rlinks{ display:flex; gap:12px; }
  mark{ background:rgba(34,211,238,.22); color:var(--fg); border-radius:2px; padding:0 1px; }

  /* ---- Config ---- */
  .cfg-layout{ display:grid; grid-template-columns:minmax(170px, 210px) 1fr; gap:16px; align-items:start; }
  .cfg-secs{ list-style:none; padding:6px; margin:0; background:var(--surface); border:1px solid var(--border); border-radius:6px; display:flex; flex-direction:column; gap:1px; }
  .cfg-secs button{ width:100%; text-align:left; padding:7px 10px; border-radius:4px; color:var(--fg2); font-size:13px; }
  .cfg-secs button:hover{ background:var(--elev); }
  .cfg-secs button[aria-current="true"]{ color:var(--accent); background:var(--elev); box-shadow:inset 2px 0 0 var(--accent); }
  .cfg-panel{ background:var(--surface); border:1px solid var(--border); border-radius:6px; padding:14px 18px; }
  .cfg-field{ display:grid; grid-template-columns:180px 1fr; gap:14px; align-items:center; padding:10px 0; border-bottom:1px solid var(--border); }
  .cfg-field:last-child{ border-bottom:none; }
  .cfg-field .fname{ color:var(--fg2); font-family:var(--mono); font-size:13px; }
  .cfg-field .fdesc{ color:var(--fg2); font-family:var(--ui); font-size:11.5px; opacity:.75; margin-top:2px; max-width:52ch; line-height:1.45; }
  select.cfg-in{ background:var(--elev); color:var(--fg); border:1px solid var(--border); border-radius:4px; padding:4px 8px; font:13px var(--mono); }
  .bgrow{ display:flex; align-items:center; gap:10px; margin:10px 0; }
  .bgrow label{ min-width:130px; color:var(--fg2); font-size:13px; }
  .bgrow input[type=range]{ flex:1; }
  .bgrow input[type=color]{ width:44px; height:28px; padding:0; border:1px solid var(--border); border-radius:4px; background:none; cursor:pointer; }
  .cfg-val{ font-family:var(--mono); display:flex; align-items:center; gap:10px; flex-wrap:wrap; }
  .cfg-in{ background:var(--elev); border:1px solid var(--border-strong); border-radius:4px; padding:5px 9px; color:var(--fg); font-family:var(--mono); font-size:13px; width:280px; max-width:100%; }
  .cfg-in:focus{ outline:2px solid var(--focus); outline-offset:1px; }
  .cfg-err{ color:var(--error); font-size:12px; }
  .cfg-note{ color:var(--fg2); font-size:12px; margin:2px 0 12px; }
  .receipts{ margin-top:16px; border-top:1px solid var(--border); padding-top:12px; }
  .receipts .rc{ font-family:var(--mono); font-size:12px; color:var(--fg2); padding:2px 0; }
  /* Crew dispatch (dash-crew-dispatch): read-only rule cards + a raw-JSON editor. */
  .disp-rules{ display:flex; flex-direction:column; gap:8px; margin:8px 0; }
  .disp-rule{ border:1px solid var(--border); border-radius:6px; padding:9px 12px; background:var(--surface); }
  .disp-h{ display:flex; align-items:center; gap:8px; flex-wrap:wrap; margin-bottom:4px; }
  .disp-when{ font-size:13px; line-height:1.5; color:var(--fg); }
  .disp-why{ font-size:12px; color:var(--fg2); margin-top:3px; font-style:italic; }
  .disp-ta{ width:100%; min-height:320px; margin-top:8px; box-sizing:border-box; font-family:var(--mono); font-size:12.5px; line-height:1.5; padding:10px 12px; border:1px solid var(--border); border-radius:6px; background:var(--canvas); color:var(--fg); resize:vertical; }
  .disp-ta:focus{ outline:none; border-color:var(--accent); }

  /* ---- dialog ---- */
  /* Above #toolview (61): a modal dialog (e.g. opened via #bg-btn, which stays
     clickable while a tool panel is open) must paint over it, not behind it. */
  .backdrop{ position:fixed; inset:0; background:rgba(3,6,10,.6); display:flex; align-items:center; justify-content:center; z-index:62; padding:20px; }
  .dialog{ background:var(--elev); border:1px solid var(--border-strong); border-radius:8px; padding:18px 20px; width:min(540px, 96vw); box-shadow:0 16px 48px rgba(0,0,0,.55); }
  .dialog h2{ font-size:16px; margin-bottom:10px; }
  .dialog .dl{ font-family:var(--mono); font-size:13px; background:var(--canvas); border:1px solid var(--border); border-radius:6px; padding:10px 12px; margin:8px 0; }
  .dialog .dl .o{ color:var(--error); } .dialog .dl .nv{ color:var(--success); }
  .dialog .eff{ color:var(--fg2); font-size:13px; }
  .dialog .dbtns{ display:flex; justify-content:flex-end; gap:8px; margin-top:16px; }

  @media (max-width:1100px){
    .md-layout{ grid-template-columns:minmax(210px, 280px) 1fr; }
    .cfg-layout{ grid-template-columns:170px 1fr; }
    .grid{ grid-template-columns:repeat(auto-fill, minmax(280px, 1fr)); }
  }

  /* ---- Board (dashboard-board): kanban by backlog status + task-detail overlay.
     Colors consume ONLY the semantic tokens above - theme-agnostic by design. ---- */
  .board{ display:grid; grid-template-columns:repeat(3,1fr); gap:14px; align-items:start; }
  .board.hidden-done{ grid-template-columns:repeat(2,1fr); }
  @media (max-width:900px){ .board, .board.hidden-done{ grid-template-columns:1fr; } }
  /* Hide-Done toggle (dashboard-board-v2): a pill switch in the board toolbar. */
  .btoggle{ display:inline-flex; align-items:center; gap:8px; border:1px solid var(--line); background:var(--panel); border-radius:9px; padding:6px 12px; font-size:12.5px; color:var(--ink); font-weight:500; margin-left:auto; }
  .btoggle .sw{ width:30px; height:17px; border-radius:20px; background:var(--border-strong); position:relative; transition:background .15s; }
  .btoggle .sw::after{ content:""; position:absolute; top:2px; left:2px; width:13px; height:13px; border-radius:50%; background:#fff; box-shadow:0 1px 2px rgba(0,0,0,.25); transition:left .15s; }
  .btoggle[aria-pressed="true"] .sw{ background:var(--accent); }
  .btoggle[aria-pressed="true"] .sw::after{ left:15px; }
  .bcol .bch .eye{ font-size:13px; color:var(--muted); cursor:pointer; border:none; background:none; padding:0 2px; line-height:1; }
  .bcol .bch .eye:hover{ color:var(--accent); }
  .bcol{ background:var(--panel); border:1px solid var(--line); border-radius:10px; padding:10px 10px 14px; min-height:120px; }
  .bcol .bch{ display:flex; align-items:center; gap:8px; font-weight:700; font-size:12px; letter-spacing:.03em; text-transform:uppercase; color:var(--muted); padding:2px 4px 10px; }
  .bcol .bch .bar{ width:11px; height:11px; border-radius:3px; }
  .bcol.flight .bch .bar{ background:var(--accent); } .bcol.queued .bch .bar{ background:var(--warn); } .bcol.done .bch .bar{ background:var(--good); }
  .bcol .bch .cnt{ margin-left:auto; background:var(--panel-2); border:1px solid var(--line); border-radius:20px; font-size:11px; padding:0 8px; color:var(--muted); font-weight:600; }
  .bcard{ display:block; width:100%; text-align:left; background:var(--panel-2); border:1px solid var(--line); border-left:3px solid var(--line); border-radius:8px; padding:10px 11px; margin:8px 0 0; cursor:pointer; transition:border-color .12s, box-shadow .12s, transform .12s; }
  .bcard:hover, .bcard:focus-visible{ border-color:var(--accent); box-shadow:var(--shadow-card); transform:translateY(-1px); text-decoration:none; }
  /* Status spine (ui-ux-pro-max: state readable at a scan, color+position not
     color alone - the badge/chips still carry the words). Same d.state
     vocabulary as STORY_BADGE, never re-derived. Hover keeps the spine hue. */
  .bcard.st-in_flight{ border-left-color:var(--success); }
  .bcard.st-done{ border-left-color:var(--accent); }
  .bcard.st-failed{ border-left-color:var(--error); }
  .bcard.st-abandoned{ border-left-color:var(--stale); }
  .bcard.st-in_flight:hover{ border-left-color:var(--success); }
  .bcard.st-done:hover{ border-left-color:var(--accent); }
  .bcard.st-failed:hover{ border-left-color:var(--error); }
  .bcard.st-abandoned:hover{ border-left-color:var(--stale); }
  .bcard .cid{ font-family:var(--mono); font-size:12px; font-weight:700; color:var(--accent); word-break:break-all; }
  .bcard .ct{ font-size:12.5px; color:var(--ink); margin:3px 0 7px; line-height:1.4; display:-webkit-box; -webkit-line-clamp:2; -webkit-box-orient:vertical; overflow:hidden; }
  .bcard .brow{ display:flex; gap:6px; align-items:center; flex-wrap:wrap; font-size:11px; color:var(--muted); }
  .chipm{ display:inline-block; background:var(--panel); border:1px solid var(--line); border-radius:5px; padding:1px 6px; font-size:10.5px; color:var(--muted); white-space:nowrap; }
  .chipm.shared{ color:var(--success); border-color:var(--success); }
  .chipm.g{ background:var(--good-soft); color:var(--good); border-color:transparent; } .chipm.a{ background:var(--accent-soft); color:var(--accent); border-color:transparent; }
  /* Delivery-contract chips: SOLID = pinned on the row (the captain's word),
     HOLLOW (dashed outline) = chief-chosen at intake, shown for the audit. */
  .chipm.cpin{ background:var(--accent-soft); color:var(--accent); border:1px solid var(--accent); font-weight:600; }
  .chipm.cauto{ background:transparent; color:var(--muted); border:1px dashed var(--muted); }
  .badgeb{ display:inline-block; border-radius:20px; padding:0 7px; font-size:10px; font-weight:700; }
  .badgeb.epic{ background:var(--purple-soft); color:var(--purple); } .badgeb.pr{ background:var(--good); color:var(--bg); }
  .bprog{ height:5px; background:var(--panel); border:1px solid var(--line); border-radius:5px; overflow:hidden; margin:8px 0 4px; }
  .bprog i{ display:block; height:100%; background:var(--good); }
  .bprog i.err{ background:var(--error); } .bprog i.stale{ background:var(--stale); }
  .broll{ font-size:11px; color:var(--muted); margin-top:5px; }
  /* Epic story sub-list (board-epic-story-legibility-v2): a wrapping grid of
     small state-colored chips - id + icon only, no description/blocked-by text
     - so 9 near-identical rows become one scannable block instead of a column
     that runs off the card. Reuses the EXISTING .badge tokens (:5171-5176):
     ok=done, accent=in flight, err=failed, stale=abandoned, unmodified=queued. */
  .bsubs{ display:flex; flex-wrap:wrap; gap:4px; margin-top:6px; }
  .bsubs .badge{ max-width:100%; overflow:hidden; text-overflow:ellipsis; }
  .bcard .live{ margin-left:auto; }
  .bempty{ color:var(--muted); font-size:12px; padding:16px 10px; text-align:center; border:1px dashed var(--line); border-radius:8px; margin-top:8px; }
  .kpis{ display:grid; grid-template-columns:repeat(auto-fit, minmax(140px, 1fr)); gap:10px; margin-bottom:14px; }
  .kpi{ background:var(--panel); border:1px solid var(--line); border-radius:10px; padding:10px 14px; display:flex; align-items:baseline; gap:10px; }
  .kpi b{ font-family:var(--mono); font-size:22px; font-weight:700; color:var(--ink); }
  .kpi span{ font-size:11px; text-transform:uppercase; letter-spacing:.04em; color:var(--muted); }
  .kpi.ok b{ color:var(--success); }
  .kpi.warn{ border-color:var(--warning); background:var(--warn-soft); }
  .kpi.warn b{ color:var(--warning); }
  /* Live system/paned task (board-live-panes): muted + dashed so background machinery reads distinct from backlog work, in both themes (design tokens only). */
  .bcard.sys{ background:var(--panel); border-style:dashed; cursor:default; }
  .bcard.sys:hover, .bcard.sys:focus-visible{ border-color:var(--line); box-shadow:none; transform:none; }
  .bcard.sys .cid{ color:var(--muted); }
  .badgeb.sys{ background:var(--panel-2); color:var(--muted); border:1px solid var(--line); font-weight:600; text-transform:uppercase; letter-spacing:.03em; }

  /* ---- task-detail: near-full-screen master-detail (dashboard-board-v2) ---- */
  /* The detail is a PAGE now, not a modal: it fills the page column and scrolls
     with it, so there is no scrim, no z-index race with the tool view, and no
     second Escape-to-close contract - Back is the browser's own. */
  .bdetail{ background:var(--panel); border:none; border-radius:0; width:100%; max-width:none; margin:0; overflow:hidden; display:flex; flex-direction:column; min-height:0; }
  .bdetail.inpage{ height:calc(100vh - 90px); }
  .bback{ display:inline-block; align-self:flex-start; margin:0 0 2px 2px; padding:4px 10px; font-size:12.5px; color:var(--muted); border:1px solid var(--line); border-radius:7px; background:var(--bg); }
  .bback:hover{ color:var(--accent); border-color:var(--accent); text-decoration:none; }
  .bdetail .fhead{ display:flex; align-items:center; gap:11px; padding:14px 20px; border-bottom:1px solid var(--line); background:var(--panel-2); flex:0 0 auto; }
  .bdetail .fhead .did{ font-family:var(--mono); font-weight:700; font-size:17px; letter-spacing:-.01em; color:var(--ink); word-break:break-all; }
  .bdetail .fhead .stt{ background:var(--good-soft); color:var(--good); border-radius:6px; font-size:11px; padding:3px 9px; font-weight:600; }
  .bdetail .fhead .stt.q{ background:var(--warn-soft); color:var(--warn); } .bdetail .fhead .stt.f{ background:var(--accent-soft); color:var(--accent); }
  .bdetail .fhead .stt.err{ background:transparent; color:var(--error); border:1px solid var(--error); } .bdetail .fhead .stt.stale{ background:transparent; color:var(--stale); border:1px solid var(--stale); }
  .bdetail .fhead .x{ margin-left:auto; font-size:18px; color:var(--muted); border:1px solid var(--line); border-radius:9px; width:32px; height:32px; display:flex; align-items:center; justify-content:center; flex:0 0 auto; }
  .bdetail .fhead .x:hover{ background:var(--bg); color:var(--ink); }
  .bdetail .fbody{ flex:1 1 auto; display:grid; grid-template-columns:300px 1fr; min-height:0; }
  .bdetail .fbody.haschief{ grid-template-columns:300px 1fr 6px var(--chiefw, minmax(360px,34%)); }
  @media (max-width:720px){ .bdetail .fbody, .bdetail .fbody.haschief{ grid-template-columns:1fr; } .bdetail .rail{ max-height:40%; } }
  .chiefp{ border-left:1px solid var(--line); background:var(--panel); display:flex; flex-direction:column; min-height:0; }
  .chiefp .cbar{ display:flex; align-items:center; gap:8px; padding:8px 12px; border-bottom:1px solid var(--line); font-size:12px; color:var(--muted); }
  .chiefp .cbar b{ color:var(--ink); font-family:var(--mono); font-weight:600; }
  .chiefp .cbar .cbtn{ margin-left:auto; font:600 11px var(--mono); padding:3px 10px; border:1px solid var(--line); border-radius:4px; background:var(--elev); color:var(--muted); cursor:pointer; }
  .chiefp .cbar .cbtn[aria-pressed="true"]{ color:var(--accent); border-color:var(--accent); }
  .chiefp .cbar .cbtn:hover{ border-color:var(--border-strong); color:var(--ink); }
  /* Page tokens, not a hardcoded slab: the web terminal takes --term-bg/--term-fg
     (the captain's Warp dark_city surface in dark, the page canvas in light)
     through acSetTheme, so the snapshot pane reads the SAME pair - one terminal
     look, both surfaces - and the same JetBrains Mono the captain's Warp runs. */
  .chiefp .cterm{ flex:1 1 auto; overflow-y:auto; overflow-x:hidden; margin:0; padding:10px 12px; background:var(--term-bg, var(--canvas)); color:var(--term-fg, var(--fg));
    font:12px/1.45 'JetBrains Mono', var(--mono); white-space:pre-wrap; word-break:break-word;
    /* Same white stripe the web terminal had: the UA's light scrollbar track
       against a dark pane. Wheel still scrolls; only the bar is gone. */
    scrollbar-width:none; -ms-overflow-style:none; }
  .chiefp .cterm::-webkit-scrollbar{ width:0; height:0; }
  .chiefp .cterm .csep{ display:inline-block; max-width:100%; white-space:nowrap; overflow:hidden; vertical-align:bottom; }
  .chiefp .cterm a{ color:var(--accent); text-decoration:underline; cursor:pointer; }
  .chiefp .cdead{ padding:14px; color:var(--muted); font-size:12.5px; }
  .chiefp .ckeys{ display:flex; gap:6px; padding:6px 10px; border-top:1px solid var(--line); }
  .chiefp .ckeys button{ font:600 11px var(--mono); padding:3px 10px; border:1px solid var(--line); border-radius:4px; background:var(--elev); color:var(--muted); cursor:pointer; }
  .chiefp .ckeys button:hover{ color:var(--ink); border-color:var(--line-strong); }
  .chiefp .ckeys #chief-kb.on{ color:var(--accent); border-color:var(--accent); }
  .chiefp .csend{ display:flex; gap:8px; padding:8px 10px; border-top:1px solid var(--line); align-items:flex-end; }
  .chiefp .csend textarea{ flex:1; resize:none; background:var(--elev); color:var(--ink); border:1px solid var(--line); border-radius:6px; padding:7px 9px; font:12.5px var(--ui); }
  .chiefp .cnote{ padding:0 12px 8px; font-size:11.5px; color:var(--muted); min-height:16px; }
  .chiefp .cnote.err{ color:var(--error); }
  .chiefp .ctabs{ display:flex; flex-wrap:wrap; gap:7px; padding:8px 12px; background:var(--panel-2, var(--surface)); border-bottom:1px solid var(--line); }
  .chiefp .ctabs:empty{ display:none; }
  .chiefp .ctabs .ct{ display:inline-flex; align-items:center; gap:6px; font:600 11.5px var(--mono); padding:4px 12px;
    border:1px solid var(--line); border-radius:999px; background:var(--elev); color:var(--muted); cursor:pointer;
    max-width:300px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; transition:border-color .12s, color .12s; }
  .chiefp .ctabs .ct .k{ font:500 10px var(--ui); text-transform:uppercase; letter-spacing:.05em; opacity:.65;
    border:1px solid var(--line); border-radius:3px; padding:0 5px; }
  .chiefp .ctabs .ct .dot{ width:7px; height:7px; border-radius:50%; background:var(--success); }
  .chiefp .ctabs .ct.on{ color:var(--accent-ink, #04252c); border-color:var(--accent); background:var(--accent); font-weight:700; }
  .chiefp .ctabs .ct.on .k{ border-color:var(--accent-ink, #04252c); color:var(--accent-ink, #04252c); opacity:.85; }
  .chiefp .ctabs .ct.on .dot{ background:var(--accent-ink, #04252c); }
  .chiefp .ctabs .ct:hover{ border-color:var(--border-strong); color:var(--ink); }
  /* FULL-BLEED terminal surfaces: a terminal
     is the one page whose content is measured in COLUMNS, so every pixel the
     chrome keeps costs readable text - the pane snapshot wrapped mid-word and
     the herdr frame cut its own lines off at the right edge. Both cancel the
     page gutter exactly (the --pagepad-* vars above) and drop the frame's
     border/radius; termFit then measures the real offset for height (it fits
     whichever of the two is mounted - one measurer, never two). */
  .chatpage, .termpage{ height:calc(100vh - 130px); min-height:420px; /* fallback; the fit fns measure the real offset */
    margin:calc(-1 * var(--pagepad-y)) calc(-1 * var(--pagepad-x)); }
  .chatpage .chiefp{ height:100%; border:0; border-radius:0; overflow:hidden; }
  .termpage iframe{ width:100%; height:100%; border:0; border-radius:0; background:var(--term-bg, var(--canvas)); }
  .termpage{ position:relative; overflow:hidden; }
  /* full-bleed routes: the page shell's bottom padding is the last 15px of
     scroll height (measured), and zoom rounding adds the rest - kill both so
     the viewport-fitted pane never grows scrollbars */
  .page:has(.termpage), .page:has(.chatpage){ padding-bottom:0; }
  /* and the document itself never scrolls on full-bleed routes: transient
     overflow during poll re-renders flickered both bars in and out */
  html:has(.termpage), html:has(.chatpage){ overflow:hidden; }
  body:has(.termpage), body:has(.chatpage){ overflow:hidden; }
  .termpage .termopen{ position:absolute; top:8px; right:14px; z-index:2; font-size:13px; line-height:1; padding:5px 8px; border-radius:6px; background:var(--surface); border:1px solid var(--border); color:var(--fg2); opacity:.55; }
  .termpage .termopen:hover{ opacity:1; color:var(--accent); border-color:var(--border-strong); text-decoration:none; }
  .termpage .cdead{ padding:16px; color:var(--muted); }
  .cgrip{ cursor:col-resize; background:var(--line); width:6px; }
  .cgrip:hover, .cgrip:active{ background:var(--accent); }
  .ovroom{ margin-top:18px; }
  .ovroom b{ display:block; font-size:12px; text-transform:uppercase; letter-spacing:.05em; color:var(--fg2); margin-bottom:8px; }
  .ovroom .re{ padding:5px 0; border-top:1px solid var(--line); font-size:12.5px; line-height:1.55; white-space:pre-wrap; word-break:break-word; }
  .ovroom .rets{ color:var(--fg2); font-size:11px; }
  .ovroom .rea{ color:var(--fg2); font-size:11px; }
  .ovstories{ margin-top:14px; }
  /* Each story is a bordered card row, not a ruled text list (captain 2026-08-17). */
  .ovstories .strow{ display:flex; align-items:center; gap:10px; padding:9px 12px; margin:6px 0;
    background:var(--surface); border:1px solid var(--border); border-radius:8px; color:var(--fg); min-width:0; }
  .ovstories .strow:hover{ border-color:var(--border-strong); background:var(--elev); text-decoration:none; }
  .ovstories .stid{ font-family:var(--mono); font-size:11.5px; font-weight:700; color:var(--accent); flex:0 0 auto; max-width:28ch; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .ovstories .srepo{ font-family:var(--mono); font-size:9.5px; font-weight:700; color:var(--accent); background:var(--accent-soft);
    border-radius:5px; padding:1px 6px; flex:0 0 auto; max-width:20ch; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .ovstories .spr{ font-family:var(--mono); font-size:9.5px; font-weight:700; color:var(--success); border:1px solid var(--success);
    border-radius:5px; padding:0 6px; flex:0 0 auto; }
  .ovstories .badge{ flex:0 0 auto; }
  .ovstories .sttx{ flex:1 1 auto; min-width:0; display:-webkit-box; -webkit-line-clamp:2; -webkit-box-orient:vertical;
    overflow:hidden; white-space:normal; font-size:12.5px; line-height:1.45; }
  .ovroom .rev{ font-weight:700; font-family:var(--mono); font-size:11px; padding:1px 6px; border-radius:4px; background:var(--elev); }
  .ovroom .rev.warn{ color:var(--warning); border:1px solid var(--warning); }
  .ovroom .rev.ok{ color:var(--success); }
  .ovroom .rev.acc{ color:var(--accent); }
  .chiefp .cbar .cback{ font-size:15px; line-height:1; padding:2px 9px; border:1px solid var(--line); border-radius:4px;
    color:var(--muted); text-decoration:none; }
  .chiefp .cbar .cback:hover{ color:var(--accent); border-color:var(--accent); text-decoration:none; }
  .story .fopen{ margin-left:auto; font-size:11px; padding:1px 7px; border:1px solid var(--line); border-radius:4px; background:var(--elev); color:var(--muted); cursor:pointer; }
  .story .fopen:hover{ color:var(--accent); border-color:var(--accent); }
  .bdetail .rail{ border-right:1px solid var(--line); background:var(--panel); overflow:auto; padding:16px; }
  .bdetail h4{ margin:16px 0 8px; font-size:10.5px; text-transform:uppercase; letter-spacing:.05em; color:var(--muted); font-weight:700; }
  .bdetail h4:first-child{ margin-top:0; }
  .bdetail .prog{ height:8px; background:var(--bg); border:1px solid var(--line); border-radius:5px; overflow:hidden; }
  .bdetail .prog i{ display:block; height:100%; background:var(--good); }
  .bdetail .prog i.err{ background:var(--error); } .bdetail .prog i.stale{ background:var(--stale); }
  .bdetail .plabel{ font-size:12px; color:var(--muted); margin-top:4px; }
  .bdetail .stage{ margin:8px 0; }
  .bdetail .stage .sh{ display:flex; align-items:center; gap:7px; font-weight:600; font-size:12.5px; color:var(--ink); cursor:pointer; padding:2px 0; }
  .bdetail .stage .sh .chev{ color:var(--muted); font-size:10px; width:11px; transition:transform .15s; }
  .bdetail .stage.collapsed .sh .chev{ transform:rotate(-90deg); }
  .bdetail .stage.collapsed .arts{ display:none; }
  .bdetail .stage .sh .tick{ color:var(--good); font-weight:700; }
  .bdetail .stage .sh .n{ color:var(--muted); font-weight:400; font-size:11px; }
  .bdetail .arts{ margin:4px 0 4px 15px; border-left:2px solid var(--line); padding-left:9px; }
  .bdetail .story{ margin:7px 0; border:1px solid var(--line); border-radius:9px; overflow:hidden; background:var(--panel); }
  .bdetail .story .sh{ display:flex; align-items:center; gap:7px; font-weight:600; font-size:12.5px; color:var(--ink); cursor:pointer; padding:8px 10px; background:var(--bg); }
  .bdetail .story .sh .chev{ color:var(--muted); font-size:10px; width:11px; transition:transform .15s; }
  .bdetail .story.collapsed .sh .chev{ transform:rotate(-90deg); }
  .bdetail .story.collapsed .arts{ display:none; }
  /* One line, ellipsized - a long repo name must not stack the story row
     three chips tall (epic-stories-compact follow-up). */
  .bdetail .story .repo{ background:var(--accent-soft); color:var(--accent); border-radius:5px; font-size:9.5px; padding:1px 6px; font-weight:700; font-family:var(--mono);
    flex:0 1 auto; min-width:0; max-width:14ch; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .bdetail .story .pr{ margin-left:auto; background:var(--good); color:var(--bg); border-radius:20px; font-size:9.5px; padding:1px 7px; font-weight:700; }
  .bdetail .story .arts{ padding:6px 10px 8px; margin:0; border-left:none; }
  .bdetail .story .stage{ margin:4px 0; }
  .bdetail .art{ display:flex; align-items:center; gap:7px; font-size:12px; color:var(--accent); padding:4px 8px; border-radius:7px; cursor:pointer; font-family:var(--mono); width:100%; text-align:left; }
  .bdetail .art:hover{ background:var(--accent-soft); }
  .bdetail .art.on{ background:var(--accent-soft); color:var(--accent); font-weight:700; }
  .bdetail .art .dot{ width:5px; height:5px; border-radius:50%; background:var(--accent); flex:0 0 auto; }
  .bdetail .art.html{ color:var(--purple); } .bdetail .art.html .dot{ background:var(--purple); } .bdetail .art.on.html{ background:var(--purple-soft); }
  .bdetail .art.plan{ color:var(--warn); } .bdetail .art.plan .dot{ background:var(--warn); } .bdetail .art.on.plan{ background:var(--warn-soft); }
  .bdetail .rlink{ display:block; color:var(--muted); font-size:12px; margin:5px 0; }
  .bdetail .rlink:hover{ color:var(--accent); }
  .bdetail .roombtn{ display:inline-block; margin-top:10px; background:var(--accent); color:var(--accent-ink); border-radius:9px; padding:8px 14px; font-size:12.5px; font-weight:600; box-shadow:var(--shadow-card); }
  .bdetail .roombtn:hover{ background:var(--accent-hover); text-decoration:none; }
  .bdetail .repotxt{ font-size:12.5px; color:var(--ink); }
  .bdetail .tlbtn{ display:flex; align-items:center; gap:6px; margin-top:10px; width:100%; text-align:left; background:var(--accent-soft); color:var(--accent); border:1px solid var(--line); border-radius:9px; padding:8px 12px; font-size:12.5px; font-weight:600; cursor:pointer; }
  .bdetail .tlbtn:hover{ background:var(--accent); color:var(--accent-ink); }
  .bdetail .tlbtn .n{ color:inherit; opacity:.75; font-weight:400; font-size:11px; }
  .bdetail .tl{ padding:20px 26px; }
  .bdetail .tlrow{ display:flex; gap:12px; padding-bottom:16px; position:relative; }
  .bdetail .tlrow:not(:last-child)::before{ content:''; position:absolute; left:5px; top:14px; bottom:0; width:2px; background:var(--line); }
  /* Segmented progress (progress-segments): one flex segment per stage. */
  .prog.segd{ display:flex; gap:3px; }
  .prog.segd i{ flex:1 1 0; width:auto; border-radius:3px; background:var(--elev); }
  .prog.segd i.on{ background:var(--success); }
  .prog.segd i.err{ background:var(--error); }
  .prog.segd i.stale{ background:var(--stale); }
  .bdetail .tldot{ flex:0 0 auto; width:12px; height:12px; border-radius:50%; background:var(--accent); margin-top:2px; box-shadow:0 0 0 3px var(--accent-soft); z-index:1; }
  .bdetail .tldot.warn{ background:var(--warning); box-shadow:0 0 0 3px color-mix(in srgb, var(--warning) 20%, transparent); }
  .bdetail .tldot.err{ background:var(--error); box-shadow:0 0 0 3px color-mix(in srgb, var(--error) 20%, transparent); }
  .bdetail .tl .rev{ font-weight:700; font-family:var(--mono); font-size:11px; padding:1px 6px; border-radius:4px; background:var(--elev); }
  .bdetail .tl .rev.warn{ color:var(--warning); border:1px solid var(--warning); }
  .bdetail .tl .rev.ok{ color:var(--success); }
  .bdetail .tl .rev.acc{ color:var(--accent); }
  .bdetail .tl .rev.err{ color:var(--error); border:1px solid var(--error); }
  .bdetail .tl .rev.stale{ color:var(--stale); }
  .bdetail .tlmain{ min-width:0; flex:1 1 auto; }
  .bdetail .tlline{ font-size:13px; color:var(--ink); word-break:break-word; line-height:1.45; }
  .bdetail .tlmeta{ display:flex; align-items:center; gap:8px; margin-top:3px; }
  .bdetail .tlclock{ font-family:var(--mono); font-size:11px; color:var(--muted); }
  .bdetail .tldelta{ font-family:var(--mono); font-size:10.5px; color:var(--accent); background:var(--accent-soft); border-radius:5px; padding:1px 6px; font-weight:600; }
  .bdetail .viewer{ position:static; top:auto; height:auto; overflow:hidden; background:var(--bg); min-height:0; display:flex; flex-direction:column; }
  .bdetail .vbar{ display:flex; align-items:center; gap:8px; padding:10px 18px; border-bottom:1px solid var(--line); background:var(--panel); font-size:12.5px; flex:0 0 auto; }
  .bdetail .vbar .vpath{ font-family:var(--mono); color:var(--muted); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .bdetail .vbar .vkind{ margin-left:auto; background:var(--purple-soft); color:var(--purple); border-radius:6px; font-size:10.5px; padding:2px 8px; font-weight:700; text-transform:uppercase; flex:0 0 auto; }
  .bdetail .vbar .vkind.md{ background:var(--good-soft); color:var(--good); }
  .bdetail .vbody{ flex:1 1 auto; overflow:auto; min-height:0; }
  .bdetail .vbody .vmd{ padding:22px 28px; background:var(--panel); min-height:100%; }
  .bdetail .vbody .vframe{ width:100%; height:100%; border:0; background:#fff; }
  .bdetail .vbody .vimg{ display:block; max-width:100%; margin:16px auto; }
  .bdetail .vbody .vtext{ font-family:var(--mono); font-size:12px; line-height:1.5; white-space:pre; margin:0; padding:18px 22px; color:var(--ink); }
  .bdetail .overview{ padding:22px 28px; }
  .bdetail .overview h3{ margin:0 0 4px; font-size:18px; color:var(--accent); font-weight:700; }
  .bdetail .overview .ovsub{ color:var(--muted); font-size:12.5px; margin-bottom:14px; }
  .bdetail .overview .ovrow{ display:grid; grid-template-columns:1fr 1fr; gap:12px; margin:12px 0; }
  /* Description owns a full row (board-detail-ux): the long prose block was
     paired with the one-chip Repo block, half the width empty. The compact
     fact blocks pair up beneath it. */
  .bdetail .overview .ovb.wide{ grid-column:1 / -1; }
  @media (max-width:720px){ .bdetail .overview .ovrow{ grid-template-columns:1fr; } }
  .bdetail .overview .ovb{ background:var(--bg); border:1px solid var(--line); border-radius:11px; padding:13px 15px; }
  .bdetail .overview .ovb b{ color:var(--ink); font-size:13px; } .bdetail .overview .ovb p{ margin:5px 0 0; font-size:12px; color:var(--muted); word-break:break-word; }
  .bdetail .overview .ovprs{ margin-top:12px; }
  .bdetail .overview .ovprs b{ display:block; font-size:12px; text-transform:uppercase; letter-spacing:.05em; color:var(--fg2); margin-bottom:8px; }
  .bdetail .overview .prrow{ display:flex; align-items:center; gap:8px; flex-wrap:wrap; padding:7px 0; border-top:1px solid var(--line); text-decoration:none; }
  .bdetail .overview .prrow:hover .prn{ text-decoration:underline; }
  .bdetail .overview .prn{ font-family:var(--mono); font-size:12.5px; font-weight:700; color:var(--accent); }
  .bdetail .overview .prby{ font-family:var(--mono); font-size:11px; color:var(--fg2); }
  .join{ display:inline-block; background:var(--purple-soft); color:var(--purple); border-radius:4px; padding:0 5px; font-size:10px; font-weight:700; font-family:var(--mono); margin-left:4px; text-transform:none; letter-spacing:0; }
</style>
</head>
<body>
<div id="toolview"><div class="tbar"><span class="tname" id="tool-name"></span><a id="tool-ext" href="#" target="_blank" rel="noopener">Open in new tab &#8599;</a><button id="tool-close">Close</button></div><iframe id="tool-frame"></iframe></div>
<div class="shell">
  <nav id="sidebar" class="sidebar" aria-label="Primary navigation">
    <div class="brand"><span class="anchor">&#9875;</span><span class="brandtext">AGENT CREW</span></div>
    <div class="navsec">
      <a class="navitem" href="/fleets" data-nav="/fleets"><span class="ico">&#9635;</span><span class="lbl">Fleets</span></a>
      <ul id="fleet-list" class="fleetlist" aria-label="Fleets"></ul>
      <a class="navitem" href="/search" data-nav="/search"><span class="ico">&#9906;</span><span class="lbl">Search</span></a>
      <a class="navitem" href="/terminal" data-nav="/terminal"><span class="ico">&#10095;</span><span class="lbl">Terminal</span></a>
    </div>
    <div class="navsec">
      <div class="navcap">Selected fleet</div>
      <div id="sel-name" class="selname mono">&mdash;</div>
      <ul id="page-nav" class="pagenav" aria-label="Fleet pages"></ul>
    </div>
    <div class="navspacer"></div>
    <div id="sys-health" class="sys" aria-label="System health" aria-live="polite"></div>
    <button id="collapse-btn" class="collapse" type="button" aria-label="Collapse sidebar" aria-pressed="false"><span class="clbl">Collapse</span><span class="cico" aria-hidden="true">&#8676;</span></button>
  </nav>
  <main id="main" class="main">
    <header class="pagehead">
      <div class="headline">
        <h1 id="page-title">Fleets</h1>
        <div id="page-crumb" class="crumb"></div>
        <div id="page-meta" class="meta"></div>
      </div>
      <div class="actions">
        <span id="live" class="live" role="status" aria-live="polite"><span class="dot" aria-hidden="true"></span><span id="live-text">connecting&hellip;</span></span>
        <button id="theme-btn" class="btn sm" type="button" aria-label="Cycle theme: auto, light, dark" title="Cycle theme: auto, light, dark">&#127765;</button>
        <button id="palette-btn" class="btn sm" type="button" aria-label="Cycle accent palette: cyan, teal, navy" title="Cycle accent palette: cyan, teal, navy">Cyan</button>
        <button id="bg-btn" class="btn sm" type="button" aria-label="Background: custom canvas color or wallpaper (default follows the theme)" title="Background: custom canvas color or wallpaper (default follows the theme)">&#128444;&#65039;</button>
        <button id="refresh-btn" class="btn sm" type="button">&#8635; Refresh</button>
      </div>
    </header>
    <div id="page" class="page" tabindex="-1" aria-live="polite">
      <div class="skeleton"><div class="sk"></div><div class="sk"></div><div class="sk"></div></div>
    </div>
  </main>
</div>
<div id="dialog-root"></div>
<script>
"use strict";
var POLL_MS = 5000;

// The server->client interpolations in this page: the Reports folder tree is
// grouped, the Open-external button gated, the per-fleet cadence line
// labelled, and a verify[] entry bucketed into a Processes row - by the SAME
// pure functions the bun test proves (see groupArtifacts, isHtmlArtifact,
// cadenceLabel, verifyProcessRows).
${groupArtifacts.toString()}
${isHtmlArtifact.toString()}
${reviewableArtifact.toString()}
${cadenceLabel.toString()}
${fleetAttnItems.toString()}
${verifyProcessRows.toString()}
// Board (dashboard-board): the card join runs the SAME bun-tested joiners the
// server does - one source of truth, no client re-implementation.
${parseBacklogLine.toString()}
${contractTokens.toString()}
${storyState.toString()}
${familyOfTaskId.toString()}
${boardSystemPanes.toString()}
${deriveProgress.toString()}
${familyRepos.toString()}
${familyStages.toString()}
${parseTimeline.toString()}
${composeFamily.toString()}
// Theme + palette toggles (theme-revamp, theme-revamp-presets): the SAME
// resolvers the bun test proves. resolveTheme itself is not interpolated here
// - the browser never resolves "auto" in JS, the CSS :root default + the
// prefers-color-scheme media block do that natively - it stays exported only
// as the pure spec the CSS mirrors and the test proves.
${nextTheme.toString()}
${resolvePalette.toString()}
${nextPalette.toString()}
function themeStored(){ try{ return localStorage.getItem('ac_dash_theme'); }catch(e){ return null; } }
// The tri-state cycle runs over the STORED value, not the resolved theme:
// "auto" is the absence of a stored key, and resolveTheme's own fallback
// already renders that correctly.
function themeState(){ var s=themeStored(); return (s==='light'||s==='dark') ? s : 'auto'; }
function setThemeLabel(){
  var b=el('theme-btn'); if(!b) return;
  var s=themeState();
  b.textContent = s==='auto' ? '\\uD83C\\uDF13' : (s==='light' ? '\\u2600\\uFE0F' : '\\uD83C\\uDF19');
}
function toggleTheme(){
  var next=nextTheme(themeState());
  if(next==='auto'){
    document.documentElement.removeAttribute('data-theme');
    try{ localStorage.removeItem('ac_dash_theme'); }catch(e){}
  } else {
    document.documentElement.setAttribute('data-theme', next);
    try{ localStorage.setItem('ac_dash_theme', next); }catch(e){}
  }
  setThemeLabel();
}
function paletteStored(){ try{ return localStorage.getItem('ac_dash_palette'); }catch(e){ return null; } }
function currentPalette(){ return resolvePalette(paletteStored()); }
function setPaletteLabel(){
  var b=el('palette-btn'); if(!b) return;
  var p=currentPalette();
  b.textContent = p.charAt(0).toUpperCase()+p.slice(1);
}
function togglePalette(){
  var next=nextPalette(currentPalette());
  if(next==='cyan') document.documentElement.removeAttribute('data-palette');
  else document.documentElement.setAttribute('data-palette', next);
  try{ if(next==='cyan') localStorage.removeItem('ac_dash_palette'); else localStorage.setItem('ac_dash_palette', next); }catch(e){}
  setPaletteLabel();
}

// ---- Background (dash-bg): custom canvas color and/or wallpaper, per browser.
// Absent keys = the theme's own canvas (the default follows the theme, exactly
// like theme "auto"). The exported normalizeBgColor/clampBgDim are the pure
// spec these inline mirrors are tested against.
function bgStored(){ try{ return { c:localStorage.getItem('ac_dash_bg'), im:localStorage.getItem('ac_dash_bg_img'), d:localStorage.getItem('ac_dash_bg_dim') }; }catch(e){ return {c:null,im:null,d:null}; } }
function bgSet(k,v){ try{ if(v==null) localStorage.removeItem(k); else localStorage.setItem(k,v); }catch(e){ return false; } return true; }
function bgDim(raw){ if(raw==null||raw==='') return 55; var d=Number(raw); if(!isFinite(d)) d=55; return Math.min(95,Math.max(0,Math.round(d))); }
function bgApply(){
  var st=document.documentElement.style, s=bgStored();
  var c=(s.c&&/^#([0-9a-f]{3}|[0-9a-f]{6})$/.test(s.c.trim().toLowerCase()))?s.c.trim():null;
  if(c) st.setProperty('--canvas', c); else st.removeProperty('--canvas');
  if(s.im&&s.im.slice(0,11)==='data:image/'){
    st.setProperty('--bg-img','url("'+s.im+'")');
    st.setProperty('--bg-img-op', String((100-bgDim(s.d))/100));
  } else { st.removeProperty('--bg-img'); st.removeProperty('--bg-img-op'); }
}
function toHex6(v){
  v=(v||'').trim().toLowerCase();
  var m3=/^#([0-9a-f])([0-9a-f])([0-9a-f])$/.exec(v);
  if(m3) return '#'+m3[1]+m3[1]+m3[2]+m3[2]+m3[3]+m3[3];
  if(/^#[0-9a-f]{6}$/.test(v)) return v;
  var m=/^rgb\\((\\d+),\\s*(\\d+),\\s*(\\d+)\\)$/.exec(v);
  if(m){ var h=function(n){ return ('0'+Number(n).toString(16)).slice(-2); }; return '#'+h(m[1])+h(m[2])+h(m[3]); }
  return '#0d1117';
}
function bgLoadImage(file){
  var rd=new FileReader();
  rd.onload=function(){
    var img=new Image();
    img.onload=function(){
      // Downscale before storing: localStorage holds ~5MB and a phone photo
      // does not fit as a data URI. 1920px max keeps a crisp 1x wallpaper.
      var MAX=1920, k=Math.min(1, MAX/Math.max(img.width,img.height));
      var cv=document.createElement('canvas');
      cv.width=Math.max(1,Math.round(img.width*k)); cv.height=Math.max(1,Math.round(img.height*k));
      cv.getContext('2d').drawImage(img,0,0,cv.width,cv.height);
      var data=cv.toDataURL('image/jpeg',0.82);
      if(!bgSet('ac_dash_bg_img',data)){
        var e2=el('bg-err'); if(e2){ e2.style.display='block'; e2.textContent='image too large for browser storage - try a smaller one'; }
        return;
      }
      bgApply(); closeDialog(); openBgDialog();
    };
    img.src=rd.result;
  };
  rd.readAsDataURL(file);
}
function openBgDialog(){
  var s=bgStored();
  var cur=toHex6(getComputedStyle(document.documentElement).getPropertyValue('--canvas'));
  var d=bgDim(s.d);
  var body='<div class="bgrow"><label for="bg-color">Canvas color</label><input type="color" id="bg-color" value="'+cur+'">'+(s.c?' <button type="button" class="btn sm" id="bg-color-clear">Theme default</button>':'')+'</div>';
  body+='<div class="bgrow"><label for="bg-img-file">Wallpaper</label><input type="file" id="bg-img-file" accept="image/*">'+(s.im?' <button type="button" class="btn sm" id="bg-img-clear">Remove</button>':'')+'</div>';
  if(s.im) body+='<div class="bgrow"><label for="bg-dim">Dim toward theme</label><input type="range" id="bg-dim" min="0" max="95" value="'+d+'"><span class="mono" id="bg-dim-val">'+d+'%</span></div>';
  body+='<div class="cfg-note">Applies live; stored in this browser only. Clearing both returns to the theme default.</div>';
  body+='<div id="bg-err" class="cfg-err" style="display:none"></div>';
  openDialog({ title:'Background', body:body, confirmLabel:'Done', onConfirm:function(){ closeDialog(); } });
  var col=el('bg-color'); if(col) col.addEventListener('input', function(){ bgSet('ac_dash_bg', col.value); bgApply(); });
  var cc=el('bg-color-clear'); if(cc) cc.addEventListener('click', function(){ bgSet('ac_dash_bg',null); bgApply(); closeDialog(); openBgDialog(); });
  var dim=el('bg-dim'); if(dim) dim.addEventListener('input', function(){ bgSet('ac_dash_bg_dim', dim.value); var v=el('bg-dim-val'); if(v) v.textContent=bgDim(dim.value)+'%'; bgApply(); });
  var fi=el('bg-img-file'); if(fi) fi.addEventListener('change', function(){ if(fi.files&&fi.files[0]) bgLoadImage(fi.files[0]); });
  var cl=el('bg-img-clear'); if(cl) cl.addEventListener('click', function(){ bgSet('ac_dash_bg_img',null); bgApply(); closeDialog(); openBgDialog(); });
}

// ===========================================================================
// State
// ===========================================================================
var S = {
  snap:null,          // last-good snapshot (fleet list + totals)
  snapFail:false,     // last snapshot poll failed (disconnected)
  updated:0,          // ms of the last good snapshot
  refreshing:false,   // a poll is in flight
  route:null,         // parsed + fleet-resolved route
  page:null,          // active route's fetched payload, or {error}
  pageFail:false,     // active route's last poll failed (stale)
  viewer:null,        // persistent reader state (reports/records)
  dlg:null,           // active modal descriptor
  cfgMsg:null,        // {name, ok, text} config write receipt/error
  cfgErr:null,        // {name, text} inline validation error
  cfgEdit:null,       // {name, buffer} the knob currently being edited
  cfgSection:null     // selected config section id
};
// per route-key UI state (filters/query/expanded/sort/scroll) - survives Back/Forward within the session.
var UI = {};
function uiFor(key){ if(!UI[key]) UI[key] = { filter:'all', query:'', exp:{}, sort:null, sortDir:1, sec:{}, pageScroll:0, listScroll:0, viewerScroll:0 }; return UI[key]; }
function routeKey(r){ return r ? (r.name + ':' + (r.fleet||'')) : 'x'; }
// Embedded tool panel: review/whiteboard open INSIDE the
// SPA content area - an iframe kept OUTSIDE the diffed render root so polling
// re-renders never wipe it; every opener also offers a new-tab escape, and a
// route change closes the panel so it can never orphan across fleets.
function toolOpen(url, title){
  var tv=document.getElementById('toolview');
  // Sit BELOW the page header: route title, fleet and
  // Live/Refresh stay visible while a tool is open. Measured per open, since
  // the header height is per-route.
  var ph=document.querySelector('.pagehead');
  tv.style.top=(ph?Math.max(0,ph.getBoundingClientRect().bottom):0)+'px';
  document.getElementById('tool-name').textContent=title||'';
  document.getElementById('tool-ext').href=url;
  document.getElementById('tool-frame').src=url;
  tv.style.display='flex';
}
function toolClose(){
  var tv=document.getElementById('toolview');
  if(!tv || tv.style.display!=='flex') return;
  tv.style.display='none';
  document.getElementById('tool-frame').src='about:blank';
}

// ===========================================================================
// Small helpers
// ===========================================================================
function esc(s){ s = (s==null?'':String(s));
  return s.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'); }
function el(id){ return document.getElementById(id); }
function enc(s){ return encodeURIComponent(s); }
function dec(s){ try { return decodeURIComponent(s); } catch(e){ return s; } }
function attr(name, v){ return v ? (' ' + name + '="' + esc(v) + '"') : ''; }

function fmtTime(ms){
  if(!ms) return '';
  var d = new Date(ms);
  function p(n){ return (n<10?'0':'')+n; }
  return d.getFullYear()+'-'+p(d.getMonth()+1)+'-'+p(d.getDate())+' '+p(d.getHours())+':'+p(d.getMinutes());
}
function clockOf(ms){
  if(!ms) return '';
  var d = new Date(ms);
  function p(n){ return (n<10?'0':'')+n; }
  return p(d.getHours())+':'+p(d.getMinutes())+':'+p(d.getSeconds());
}
function agoMs(ms){
  if(!ms) return '';
  var s = Math.max(0, Math.round((Date.now()-ms)/1000));
  if(s<60) return s+'s';
  if(s<3600) return Math.floor(s/60)+'m';
  if(s<86400) return Math.floor(s/3600)+'h';
  return Math.floor(s/86400)+'d';
}
function agoIso(iso){ if(!iso) return ''; var t = Date.parse(iso); return isNaN(t) ? '' : agoMs(t); }
function isBlockedStatus(s){ return (s||'').toLowerCase().indexOf('blocked')>=0; }
function isWaitStatus(s){ s=(s||'').toLowerCase(); return s.indexOf('wait')>=0 || s.indexOf('paused')>=0 || s.indexOf('needs-decision')>=0; }

// ===========================================================================
// DOM morph (dash-poll-scroll primitive, generalized to any container). Writes
// only where the rendered HTML actually changed; a byte-identical subtree is left
// untouched, so the reader's scroll, selection, focus and iframe identity survive.
// ===========================================================================
var lastHtml = {};
function sameKind(a,b){ return a.nodeType===b.nodeType && (a.nodeType!==1 || a.nodeName===b.nodeName); }
function syncAttrs(live,next){
  var na=next.attributes, la=live.attributes, i;
  for(i=0;i<na.length;i++){ if(live.getAttribute(na[i].name)!==na[i].value) live.setAttribute(na[i].name, na[i].value); }
  for(i=la.length-1;i>=0;i--){ if(!next.hasAttribute(la[i].name)) live.removeAttribute(la[i].name); }
}
function morphChildren(live,next){
  var lc=live.firstChild, nc=next.firstChild;
  while(nc){
    var ncNext=nc.nextSibling;
    if(!lc){ live.appendChild(nc); nc=ncNext; continue; }
    var lcNext=lc.nextSibling;
    // Preserved island (guide §8): a live element carrying data-preserve is a
    // persistent viewer whose content is mounted imperatively (iframe srcdoc,
    // rendered reader) - never re-diffed. When the next node carries the SAME
    // data-preserve key, leave the live node ENTIRELY untouched (no attr sync,
    // no recursion) so its document identity, internal scroll, text selection
    // and keyboard focus survive polling. A changed key (new selection/reload)
    // falls through to a normal replace, remounting fresh content.
    if(lc.nodeType===1 && nc.nodeType===1 && lc.nodeName===nc.nodeName){
      var lp=lc.getAttribute('data-preserve');
      if(lp!==null && lp===nc.getAttribute('data-preserve')){ lc=lcNext; nc=ncNext; continue; }
    }
    if(lc.isEqualNode(nc)){ lc=lcNext; nc=ncNext; continue; }
    if(sameKind(lc,nc)){
      if(lc.nodeType===1){ syncAttrs(lc,nc); morphChildren(lc,nc); }
      else if(lc.nodeValue!==nc.nodeValue){ lc.nodeValue=nc.nodeValue; }
      lc=lcNext; nc=ncNext; continue;
    }
    live.replaceChild(nc,lc); lc=lcNext; nc=ncNext;
  }
  while(lc){ var rm=lc; lc=lc.nextSibling; live.removeChild(rm); }
}
function morphInto(node, html, key){
  if(lastHtml[key]===html) return false;
  lastHtml[key]=html;
  var tmp=document.createElement('div'); tmp.innerHTML=html;
  morphChildren(node, tmp);
  return true;
}

// ===========================================================================
// Fleet resolution (snapshot homes + crewdeputies, flattened by unique name)
// ===========================================================================
function allFleets(snap){
  var out=[];
  (function walk(hs, parent){
    for(var i=0;i<(hs||[]).length;i++){ var h=hs[i]; out.push({h:h, parent:parent}); walk(h.crewdeputies, h.name); }
  })(snap?snap.homes:[], null);
  return out;
}
function fleetByName(snap, name){
  var fs=allFleets(snap);
  for(var i=0;i<fs.length;i++){ if(fs[i].h.name===name) return fs[i].h; }
  return null;
}
function fleetEntry(snap, name){
  var fs=allFleets(snap);
  for(var i=0;i<fs.length;i++){ if(fs[i].h.name===name) return fs[i]; }
  return null;
}
function homeName(path){ // reverse a home PATH to its fleet name via the snapshot
  var fs=allFleets(S.snap);
  for(var i=0;i<fs.length;i++){ if(fs[i].h.path===path) return fs[i].h.name; }
  return path;
}
function blockedCount(h){
  var n=0, t=h.crew&&h.crew.tasks||[];
  for(var i=0;i<t.length;i++){ if(isBlockedStatus(t[i].status)) n++; }
  return n;
}
function needsAttention(h){
  return (h.inbox && (h.inbox.pending>0 || h.inbox.handback>0)) ||
         (h.watcher && h.watcher.state!=='armed' && h.crew && h.crew.count>0) ||
         blockedCount(h)>0;
}

// ===========================================================================
// Selected fleet + navigation
// ===========================================================================
function storedFleet(){ try { return localStorage.getItem('ac_dash_fleet')||''; } catch(e){ return ''; } }
function rememberFleet(name){ if(!name) return; try { localStorage.setItem('ac_dash_fleet', name); } catch(e){} }
function currentFleet(){
  if(S.route && S.route.fleet) return S.route.fleet;
  var st=storedFleet();
  if(st && fleetByName(S.snap, st)) return st;
  var fs=allFleets(S.snap);
  return fs.length ? fs[0].h.name : '';
}

function parseRoute(path){
  var q=(path||'/').split('?')[0].split('#')[0];
  var parts=q.split('/').filter(Boolean);
  if(parts.length===0) return { name:'root' };
  if(parts.length===1 && parts[0]==='search') return { name:'search' };
  if(parts.length===1 && parts[0]==='terminal') return { name:'term' };
  if(parts.length===1 && parts[0]==='fleets') return { name:'fleets' };
  if(parts[0]==='fleets' && parts.length>=3){
    var fleet=dec(parts[1]); var pg=parts[2];
    if(pg==='processes' && parts.length===3) return { name:'processes', fleet:fleet };
    if(pg==='board' && parts.length===3) return { name:'board', fleet:fleet, fam:null };
    // A family's detail is a ROUTE, not a modal: same page, deep-linkable,
    // back/forward walks in and out of it like every other view here.
    if(pg==='board' && parts.length===4) return { name:'board', fleet:fleet, fam:dec(parts[3]) };
    if(pg==='term' && parts.length===3) return { name:'term', fleet:fleet };
    if(pg==='chat' && parts.length===3) return { name:'chat', fleet:fleet, fam:null };
    if(pg==='chat' && parts.length===4) return { name:'chat', fleet:fleet, fam:dec(parts[3]) };
    // Backlog ALIASES onto Board (menu-dedup): the two pages told the same
    // ledger, so old /backlog deep links land on the Board rather than 404.
    if(pg==='backlog' && parts.length===3) return { name:'board', fleet:fleet, fam:null };
    if(pg==='learning' && parts.length===3) return { name:'learning', fleet:fleet };
    if(pg==='brain' && parts.length===3) return { name:'brain', fleet:fleet };
    if(pg==='config' && parts.length===3) return { name:'config', fleet:fleet };
    if(pg==='reports') return { name:'reports', fleet:fleet, sel: parts.length>=4 ? dec(parts.slice(3).join('/')) : null };
    if(pg==='whiteboards') return { name:'whiteboards', fleet:fleet, sel:null };
    if(pg==='reviews' && parts.length===3) return { name:'reviews', fleet:fleet };
    if(pg==='records') return { name:'records', fleet:fleet, sel: parts.length>=4 ? dec(parts.slice(3).join('/')) : null };
    if(pg==='domains' && parts.length===3) return { name:'domains', fleet:fleet };
  }
  return { name:'notfound', path:q };
}

var pollGen=0, pageCtrl=null, pageInFlight=false, snapInFlight=false;

function navigate(path, opts){
  opts=opts||{};
  if(path===location.pathname) { return; }
  saveScroll();
  if(opts.replace) history.replaceState({}, '', path);
  else history.pushState({}, '', path);
  applyRoute(false);
}

function applyRoute(isPop){
  var prev=S.route;
  var r=parseRoute(location.pathname);
  if(r.name==='root'){ navigate('/fleets', {replace:true}); return; }
  if(r.fleet){ r.home=fleetByName(S.snap, r.fleet); rememberFleet(r.fleet); }
  var changed = !prev || prev.name!==r.name || prev.fleet!==r.fleet;
  if(changed){ pollGen++; if(pageCtrl){ try{pageCtrl.abort();}catch(e){} } pageInFlight=false; S.page=null; S.pageFail=false; toolClose(); }
  S.route=r;
  if(r.name==='config' && !S.cfgSection) S.cfgSection=CFG_SECTIONS[0].id;
  syncViewer(r);
  renderNav(); renderHead(); renderPage();
  pollRoute(false);
  restoreScroll();
}

// ===========================================================================
// Polling orchestration
// ===========================================================================
function setConn(){
  var live=el('live'), txt=el('live-text');
  if(!live) return;
  var cls='live', label='';
  if(S.snapFail){ cls+=' s-down'; label='Disconnected — retrying'; }
  else if(S.refreshing){ cls+=' s-refresh'; label='Refreshing…'; }
  else if(S.pageFail){ cls+=' s-stale'; label='Stale — last good ' + clockOf(S.updated); }
  else if(S.updated){ cls+=' s-live'; label='Live · updated ' + clockOf(S.updated); }
  else { label='Connecting…'; }
  live.className=cls; txt.textContent=label;
}

function tick(force){
  if(document.hidden && !force) return;
  pollSnapshot(force);
  pollRoute(force);
}
function pollSnapshot(force){
  if(snapInFlight) return;
  snapInFlight=true; S.refreshing=true; setConn();
  fetch('/api/snapshot.json').then(function(r){ return r.json(); }).then(function(j){
    snapInFlight=false; S.refreshing=false;
    if(j && j.error){ S.snapFail=true; setConn(); return; }
    S.snapFail=false; S.snap=j; S.updated=Date.now();
    // First time a deep-linked fleet's home resolves (snapshot arrived after boot):
    // wire up the viewer/config for the now-known home path and fetch route data.
    if(S.route && S.route.fleet && !S.route.home){
      S.route.home=fleetByName(S.snap, S.route.fleet);
      if(S.route.home){
        if(S.route.name==='config' && !S.cfgSection) S.cfgSection=CFG_SECTIONS[0].id;
        S.viewer=null; syncViewer(S.route);
        pollRoute(true);
      }
    }
    renderNav(); renderHealth(); renderHead(); setConn();
    renderPage();
  }).catch(function(){ snapInFlight=false; S.refreshing=false; S.snapFail=true; setConn(); });
}
function routeEndpoint(r){
  if(!r || !r.home) return null;
  var p=enc(r.home.path);
  if(r.name==='processes') return '/api/processes?path='+p;
  if(r.name==='board') return '/api/backlog?path='+p;
  if(r.name==='backlog') return '/api/backlog?path='+p;
  if(r.name==='reports'){ var ru=uiFor(routeKey(r)); return '/api/reports?path='+p+((ru.showAll||ru.query)?'':'&limit=20'); }
  if(r.name==='whiteboards') return '/api/whiteboard?path='+p;
  if(r.name==='reviews') return '/api/reviews?path='+p;
  if(r.name==='records') return '/api/ledgers?path='+p;
  if(r.name==='domains') return '/api/domains?path='+p;
  if(r.name==='learning') return '/api/learning?path='+p;
  if(r.name==='brain') return '/api/brain?path='+p;
  if(r.name==='config') return '/api/config-list?path='+p;
  return null;
}
function pollRoute(force){
  var ep=routeEndpoint(S.route);
  if(!ep){ return; }
  if(pageInFlight) return; // coalesce - never pile up overlapping refreshes
  var gen=pollGen;
  pageInFlight=true; S.refreshing=true; setConn();
  var ctrl=('AbortController' in window) ? new AbortController() : null; pageCtrl=ctrl;
  fetch(ep, ctrl?{signal:ctrl.signal}:{}).then(function(r){ return r.json(); }).then(function(j){
    pageInFlight=false; S.refreshing=false;
    if(gen!==pollGen) return; // route/fleet changed mid-flight - drop the stale response
    if(j && j.error){ S.pageFail=true; setConn(); renderPage(); return; }
    S.pageFail=false; S.page=j; onPageData(); renderHead(); renderPage(); setConn();
  }).catch(function(e){
    pageInFlight=false; S.refreshing=false;
    if(e && e.name==='AbortError') return;
    if(gen!==pollGen) return;
    S.pageFail=true; setConn(); renderHead(); renderPage(); // keep last-good S.page, never reload
  });
}

// after fresh route data: resolve a pending viewer + detect on-disk changes to the open reader.
function onPageData(){
  if(!S.viewer) return;
  if(S.viewer.pending){ loadViewerBody(); return; }
  if(!S.viewer.loading && S.viewer.mtime){
    var cur=selectedArtifactMtime();
    if(cur && cur!==S.viewer.mtime){ S.viewer.stale=true; S.viewer.diskMtime=cur; }
  }
}
function selectedArtifactMtime(){
  var r=S.route; if(!r||!r.sel||!S.page) return 0;
  if(r.name==='reports'){ var a=findArtifact(r.sel); return a?a.mtime:0; }
  if(r.name==='records'){ var recs=S.page.records||[]; for(var i=0;i<recs.length;i++){ if(recs[i].name===r.sel) return recs[i].mtime; } }
  return 0;
}
function findArtifact(id){
  var a=(S.page&&S.page.artifacts)||[];
  for(var i=0;i<a.length;i++){ if(a[i].id===id) return a[i]; }
  return null;
}

// ===========================================================================
// Persistent viewer (Reports / Records) - loaded on selection, never on poll.
// ===========================================================================
function syncViewer(r){
  if((r.name!=='reports' && r.name!=='records') || !r.sel){ S.viewer=null; return; }
  var key=r.name+'|'+r.sel+'|'+(r.home?r.home.path:'');
  if(S.viewer && S.viewer.key===key) return; // already showing this selection
  S.viewer={ key:key, name:r.name, sel:r.sel, homePath:(r.home?r.home.path:''), loading:true, pending:false, stale:false, gen:0 };
  loadViewerBody();
}
// Apply a /api/artifact (or /api/records) body to the viewer state. One place so
// the initial load and an explicit Reload can never render two kinds differently.
function applyBody(v,j){
  v.error=null;
  if(j && j.error){ v.error=j.error; return; }
  if(j.kind==='html'){ v.kind='html'; v.content=j.content; }
  else if(j.kind==='image'){ v.kind='image'; v.src=j.src; }
  else if(j.kind==='text'){ v.kind='text'; v.text=j.text; v.truncated=!!j.truncated; }
  else if(j.kind==='bin'){ v.kind='bin'; v.note=j.note; }
  else { v.kind='md'; v.body=j.html; }
}
function loadViewerBody(){
  var v=S.viewer; if(!v){ return; }
  // Home not resolved yet (deep-link before the first snapshot): defer - the
  // snapshot handler re-runs syncViewer with the real path. Prevents an empty
  // path=&file= fetch that would 400.
  if(!v.homePath){ v.pending=true; v.loading=false; renderPage(); return; }
  var url, title, mtime=0, kind='md', path=null;
  if(v.name==='records'){
    title=v.sel; kind='md';
    var recs=(S.page&&S.page.records)||[];
    for(var i=0;i<recs.length;i++){ if(recs[i].name===v.sel){ mtime=recs[i].mtime; } }
    url='/api/records?path='+enc(v.homePath)+'&file='+enc(v.sel);
  } else {
    var a=findArtifact(v.sel);
    if(!a){ v.pending=true; v.loading=false; renderPage(); return; } // list not loaded yet -> resolve after it arrives
    v.pending=false; title=a.family+' / '+a.stage; kind=a.kind; mtime=a.mtime; path=a.path;
    url='/api/artifact?path='+enc(v.homePath)+'&file='+enc(a.path);
  }
  v.title=title; v.kind=kind; v.mtime=mtime; v.path=path; v.loading=true; v.error=null; v.stale=false; v.diskMtime=0;
  renderPage();
  var key=v.key;
  fetch(url).then(function(r){ return r.json(); }).then(function(j){
    if(!S.viewer || S.viewer.key!==key) return; // selection changed mid-flight
    v.loading=false; v.gen=(v.gen||0)+1;
    applyBody(v, j);
    renderPage();
  }).catch(function(){
    if(!S.viewer || S.viewer.key!==key) return;
    v.loading=false; v.error='failed to load'; renderPage(); // keep the shell + list usable, never reload
  });
}
function reloadViewer(){
  var v=S.viewer; if(!v) return;
  if(v.diskMtime) v.mtime=v.diskMtime;
  v.stale=false; v.diskMtime=0; v.loading=true; v.body=null; v.content=null; v.text=null; v.src=null; v.note=null;
  renderPage();
  var url = v.name==='records'
    ? '/api/records?path='+enc(v.homePath)+'&file='+enc(v.sel)
    : '/api/artifact?path='+enc(v.homePath)+'&file='+enc(v.path);
  var key=v.key;
  fetch(url).then(function(r){ return r.json(); }).then(function(j){
    if(!S.viewer || S.viewer.key!==key) return;
    v.loading=false; v.gen=(v.gen||0)+1;
    applyBody(v, j);
    renderPage();
  }).catch(function(){ if(S.viewer&&S.viewer.key===key){ v.loading=false; v.error='failed to load'; renderPage(); } });
}

// ===========================================================================
// Shell rendering (nav / health / header) - updated in place, never rebuilt.
// ===========================================================================
function statusDot(h){
  if(h.watcher && h.watcher.state!=='armed' && h.crew && h.crew.count>0) return 'err';
  if(needsAttention(h)) return 'warn';
  if(h.crew && h.crew.count>0) return 'ok';
  return 'idle';
}
function dotColor(kind){ return kind==='err'?'var(--error)':kind==='warn'?'var(--warning)':kind==='ok'?'var(--success)':'var(--fg2)'; }

function renderNav(){
  var r=S.route||{};
  var top=document.querySelectorAll('.navitem[data-nav]');
  for(var i=0;i<top.length;i++){
    var nv=top[i].getAttribute('data-nav');
    var on=(nv==='/fleets' && (r.name==='fleets'||r.name==='root')) || (nv==='/search' && r.name==='search') || (nv==='/terminal' && r.name==='term');
    if(on) top[i].setAttribute('aria-current','page'); else top[i].removeAttribute('aria-current');
  }
  var fs=allFleets(S.snap), fl='';
  for(var k=0;k<fs.length;k++){ var h=fs[k].h; var kind=statusDot(h);
    var cur=(r.fleet===h.name)?' aria-current="page"':'';
    var dep=fs[k].parent;
    var al=dep?' aria-label="'+esc(h.name)+', deputy of '+esc(dep)+'"':'';
    fl += (dep?'<li class="dep">':'<li>')+'<a href="/fleets/'+enc(h.name)+'/processes" data-link'+cur+al+' title="'+esc(h.name)+'">';
    fl += '<span class="st" style="color:'+dotColor(kind)+'">&#9679;</span><span class="fn">'+esc(h.name)+'</span></a></li>';
  }
  if(!fs.length) fl='<li class="muted" style="padding:4px 8px;font-size:12px">no fleets</li>';
  morphInto(el('fleet-list'), fl, 'fleetnav');

  var cf=currentFleet();
  el('sel-name').textContent = cf || '—';
  // Menu order = monitoring order (menu-redesign): the MONITOR group first
  // (Board is the task surface, Processes the runtime, Chat the crewchief),
  // then WORK artifacts, then KNOWLEDGE, config last. No Backlog entry
  // (menu-dedup): Board and Backlog told the same ledger twice; /backlog
  // deep links stay alive as a parseRoute alias onto the Board.
  var groups=[
    ['Monitor', [['board','Board'],['processes','Processes'],['chat','Chat']]],
    ['Work',    [['reports','Reports'],['reviews','Reviews'],['whiteboards','Whiteboards']]],
    ['Knowledge',[['records','Records'],['brain','Brain'],['learning','Learning'],['domains','Domains']]],
    ['System',  [['config','Config']]]
  ];
  var pn='';
  for(var g=0;g<groups.length;g++){ var cap=groups[g][0], pages=groups[g][1];
    if(cap) pn+='<li class="navgap" aria-hidden="true">'+cap+'</li>';
    for(var p=0;p<pages.length;p++){ var id=pages[p][0], lbl=pages[p][1];
      if(cf){ var pc=(r.name===id && r.fleet===cf)?' aria-current="page"':'';
        pn += '<li><a href="/fleets/'+enc(cf)+'/'+id+'" data-link'+pc+'>'+lbl+'</a></li>';
      } else { pn += '<li><a aria-disabled="true">'+lbl+'</a></li>'; }
    }
  }
  morphInto(el('page-nav'), pn, 'pagenav');
}

function renderHealth(){
  var n=el('sys-health'); if(!n) return;
  var t=(S.snap&&S.snap.totals)||{homes:0,crew:0,pending:0,handback:0,watchers_down:0,learning_due:0,curate_due:0};
  var fs=allFleets(S.snap), blocked=0, attn=0;
  for(var i=0;i<fs.length;i++){ blocked+=blockedCount(fs[i].h); if(needsAttention(fs[i].h)) attn++; }
  var s='';
  s+='<div><span class="n">'+t.homes+'</span> fleets &middot; <span class="n">'+t.crew+'</span> crew</div>';
  s+='<div'+(t.pending>0?' class="w"':'')+'>'+t.pending+' pending &middot; '+t.handback+' handback</div>';
  s+='<div'+((t.watchers_down>0)?' class="e"':'')+'>'+t.watchers_down+' watcher down &middot; '+blocked+' blocked</div>';
  // The learning-loop cadence, fleet-WIDE like every other footer line: how many
  // homes have reached their own learn/curate threshold. Both numbers and the
  // >= that produced them come from ac-fleets.sh (totals) - never recomputed here.
  var ld=t.learning_due||0, cd=t.curate_due||0;
  s+='<div'+((ld+cd>0)?' class="w"':'')+'>'+ld+' learning due &middot; '+cd+' curate due</div>';
  morphInto(n, s, 'sys');
}

function renderHead(){
  var r=S.route||{name:'fleets'};
  var titles={fleets:'Fleets', processes:'Processes', board:'Board', chat:'Chat', term:'Terminal', brain:'Brain', reports:'Reports', reviews:'Reviews', whiteboards:'Whiteboards', records:'Records', domains:'Domains', learning:'Learning', search:'Search', config:'Config', notfound:'Not found', root:'Fleets'};
  el('page-title').textContent = titles[r.name]||'Dashboard';
  var crumb='';
  if(r.fleet) crumb='<b>'+esc(r.fleet)+'</b>';
  el('page-crumb').innerHTML=crumb;
  el('page-meta').innerHTML=headMeta(r);
}
// "done" means real done, not Done-SECTION membership - a [failed]/
// [abandoned] row is terminal but not done (same-done-miscount-in-three-more-
// surfaces). Reuses the bun-tested storyState (board-rollup-and-overlay-
// count-failed-as-done's fix for the epic rollup) instead of a second marker
// parser; section is fixed 'done' since every line here already comes from
// the backlog's Done section.
function realDoneCount(lines){ var n=0; for(var i=0;i<lines.length;i++){ if(storyState(lines[i],'done')==='done') n++; } return n; }
function headMeta(r){
  if(r.name==='fleets'){ var t=(S.snap&&S.snap.totals)||{}; return '<span>'+((S.snap&&allFleets(S.snap).length)||0)+' fleets</span>'; }
  if(r.name==='processes' && r.home){ var cad=cadenceLabel(r.home.cadence);
    return '<span>'+(r.home.crew?r.home.crew.count:0)+' active</span>'
      +(cad?'<span class="cadence'+(cad.due?' due':'')+'">'+esc(cad.text)+'</span>':''); }
  if(r.name==='board' && S.page && S.page.backlog){ var bb=S.page.backlog; return '<span>'+bb.in_flight.length+' in flight &middot; '+bb.queued.length+' queued &middot; '+realDoneCount(bb.done)+' done</span>'; }
  if(r.name==='reports' && S.page && S.page.artifacts){ return '<span>'+(S.page.total||S.page.artifacts.length)+' artifacts</span>'; }
  if(r.name==='records' && S.page && S.page.records){ return '<span>'+S.page.records.length+' ledgers</span>'; }
  if(r.name==='domains' && S.page && S.page.domains){ var dv=S.page.domains.filter(function(d){return d.cls==='VALID';}).length, di=S.page.domains.length-dv;
    return '<span>'+dv+' domain'+(dv===1?'':'s')+(di?' &middot; '+di+' invalid':'')+'</span>'; }
  if(r.name==='learning' && S.page){ return '<span>'+((S.page.skills||[]).length)+' skills &middot; '+((S.page.pending&&S.page.pending.raw_count)||0)+' pending &middot; '+((S.page.decisions||[]).length)+' decisions</span>'; }
  if(r.name==='config'){ var dirty=S.cfgEdit?1:0; return dirty?'<span class="badge warn">Unsaved changes '+dirty+'</span>':'<span>read-only until you edit</span>'; }
  if(r.name==='search'){ return ''; }
  return '';
}

// ===========================================================================
// Page rendering
// ===========================================================================
function skeleton(){ return '<div class="skeleton"><div class="sk"></div><div class="sk"></div><div class="sk"></div><div class="sk"></div></div>'; }
function stateBox(title, msg, cls){ return '<div class="state '+(cls||'')+'"><div class="st-title">'+esc(title)+'</div><div>'+esc(msg||'')+'</div></div>'; }

function renderPage(){
  var r=S.route, html;
  boardSyncFamily(r);   // BEFORE the render: it decides what the board page has to show
  if(!S.snap && !S.snapFail){ html=skeleton(); }
  else if(!r || r.name==='root'){ html=skeleton(); }
  else if(r.name==='fleets') html=pageFleets();
  else if(r.name==='search') html=pageSearch();
  else if(r.name==='notfound') html=pageNotFound(r);
  else if(r.fleet && S.snap && !r.home) html=stateBox('Fleet not found', 'No fleet named "'+r.fleet+'" in the current survey.', 'err');
  else if(r.fleet && !r.home) html=skeleton();
  else if(r.name==='processes') html=pageProcesses();
  else if(r.name==='board') html=pageBoard();
  else if(r.name==='chat') html=pageChat();
  else if(r.name==='term') html=pageTerm();
  else if(r.name==='reports') html=pageReports();
  else if(r.name==='whiteboards') html=pageWhiteboards();
  else if(r.name==='reviews') html=pageReviews();
  else if(r.name==='records') html=pageRecords();
  else if(r.name==='domains') html=pageDomains();
  else if(r.name==='learning') html=pageLearning();
  else if(r.name==='brain') html=pageBrain();
  else if(r.name==='config') html=pageConfig();
  else html=pageNotFound(r);
  morphInto(el('page'), html, 'page');
  // Chat tab: the panel polls its own pane API; renderPage runs every poll
  // tick, so chiefPollStart's same-target guard keeps this idempotent. On the
  // board, boardSyncFamily owns the same poll for the open family's chief.
  if(r && r.name==='chat'){ chiefNoChief=false; chiefPollStart(r.fam||true); }
  else if(chiefCur!==null && boardOpenFam===null) chiefPollStop();
  if(r && r.name==='term' && !termT && !termUrl) termPoll();
  if(r && (r.name==='term'||r.name==='chat')) termFit();
  if(r && r.name==='term') termTheme();   // frame not up yet on the first pass - the next render lands it
  if(r && r.name!=='term' && termUrl) termUrl=null;
  postFrames();
}

function pageNotFound(r){
  return '<div class="state"><div class="st-title">Page not found</div>'+
    '<div>'+esc((r&&r.path)||location.pathname)+' does not match a dashboard route.</div>'+
    '<div style="margin-top:12px"><a href="/fleets" data-link class="btn">Go to Fleets</a></div></div>';
}

// ---- Fleets ----
function pageFleets(){
  var snap=S.snap; if(!snap) return skeleton();
  var fs=allFleets(snap);
  var t=snap.totals||{}, attn=0, blocked=0;
  for(var i=0;i<fs.length;i++){ if(needsAttention(fs[i].h)) attn++; blocked+=blockedCount(fs[i].h); }
  var s='';
  s+='<div class="attn" role="group" aria-label="Fleet attention summary">';
  s+='<div class="item '+(attn>0?'a-warn':'a-ok')+'"><span class="num">'+attn+'</span><span class="lbl2">need attention</span></div>';
  s+='<div class="item '+((t.pending||0)>0?'a-warn':'a-ok')+'"><span class="num">'+(t.pending||0)+'</span><span class="lbl2">captain waits</span></div>';
  s+='<div class="item '+((t.watchers_down||0)>0?'a-err':'a-ok')+'"><span class="num">'+(t.watchers_down||0)+'</span><span class="lbl2">watcher down</span></div>';
  s+='<div class="item a-ok"><span class="num">'+(t.crew||0)+'</span><span class="lbl2">active</span></div>';
  s+='</div>';
  if(!fs.length) return s+stateBox('No fleets', 'No fleet homes under '+((snap.container)||'the container')+'.');
  // Needs-captain queue (fleets-attn-queue): the LIST behind the strip's
  // counts - each waiting item links straight at its family (or the blind
  // fleet's Processes), so monitoring starts here instead of a per-fleet hunt.
  var attq=fleetAttnItems(snap);
  if(attq.length){
    s+='<div class="attnq" role="list" aria-label="Waiting on captain">';
    for(var qi=0;qi<attq.length;qi++){ var q1=attq[qi];
      var href=q1.kind==='watcher'?'/fleets/'+enc(q1.fleet)+'/processes'
        :'/fleets/'+enc(q1.fleet)+'/board/'+enc(q1.family);
      var bcls=q1.kind==='watcher'?'err':'warn';
      var blbl=q1.kind==='watcher'?'WATCHER':(q1.kind==='handback'?'HANDBACK':'GATE/ASK');
      s+='<a class="attnq-it" role="listitem" href="'+href+'" data-link>'
        +'<span class="badge '+bcls+'">'+blbl+'</span>'
        +(q1.family?'<span class="mono fam">'+esc(q1.family)+'</span>':'')
        +'<span class="fl mono">'+esc(q1.fleet)+'</span>'
        +'<span class="tx">'+esc(q1.text)+'</span></a>';
    }
    s+='</div>';
  }
  // Group each deputy with its parent, then order groups attention-first so a
  // deputy never scatters away from its parent (entry.parent drives the grouping;
  // stable sort keeps top-level fleets in their original order within a tier).
  var groups=[], byName={};
  for(var gi=0;gi<fs.length;gi++){ var e=fs[gi];
    if(!e.parent){ var g={top:e, deps:[]}; byName[e.h.name]=g; groups.push(g); }
    else if(byName[e.parent]){ byName[e.parent].deps.push(e); }
    else { groups.push({top:e, deps:[]}); } // orphan deputy: stands as its own group
  }
  groups.sort(function(a,b){ return (needsAttention(a.top.h)?0:1)-(needsAttention(b.top.h)?0:1); });
  var sorted=[];
  for(var gj=0;gj<groups.length;gj++){ sorted.push(groups[gj].top); var ds=groups[gj].deps; for(var dj=0;dj<ds.length;dj++) sorted.push(ds[dj]); }
  s+='<div class="grid">';
  for(var k=0;k<sorted.length;k++) s+=fleetCard(sorted[k]);
  s+='</div>';
  return s;
}
function fleetCard(entry){
  var h=entry.h, kind=statusDot(h), crew=h.crew?h.crew.count:0;
  var pend=h.inbox?h.inbox.pending:0, hand=h.inbox?h.inbox.handback:0, blk=blockedCount(h);
  var wdown = h.watcher && h.watcher.state!=='armed';
  var dep=entry.parent;
  var s='<a class="card fcard'+(dep?' depcard':'')+'" href="/fleets/'+enc(h.name)+'/board" data-link'+(dep?' aria-label="'+esc(h.name)+', deputy of '+esc(dep)+'"':'')+'>';
  s+='<div class="top"><span class="fname">'+(dep?'&#8627; ':'&#9875; ')+esc(h.name)+'</span>';
  s+='<span class="dot-i" style="background:'+dotColor(kind)+'" title="'+esc(kind)+'"></span></div>';
  s+='<div class="subline">'+esc((h.config&&h.config.flow)||'auto')+(dep?' &middot; deputy of '+esc(dep):'')+(h.captain?' &middot; captain '+esc(h.captain):'')+'</div>';
  s+='<div class="stats">';
  s+='<span class="kv"><b>'+crew+'</b> active</span>';
  s+='<span class="kv"><b>'+pend+'</b> waiting</span>';
  s+='<span class="kv"><b>'+blk+'</b> blocked</span>';
  s+='</div>';
  // The learning-loop cadence of THIS fleet - a nested deputy card renders its
  // own numbers through the same call. Absent cadence => no line at all.
  var cad=cadenceLabel(h.cadence);
  if(cad) s+='<div class="cadence'+(cad.due?' due':'')+'">'+esc(cad.text)+'</div>';
  s+='<div class="attnrow">';
  s+='<span class="badge '+(wdown?'err':'ok')+'">watcher '+esc(h.watcher?h.watcher.state:'?')+(h.watcher&&h.watcher.beat?' &middot; '+agoMs(h.watcher.beat*1000):'')+'</span>';
  if(pend>0) s+='<span class="badge warn">'+pend+' pending</span>';
  if(hand>0) s+='<span class="badge warn">'+hand+' handback</span>';
  if(h.wakes>0) s+='<span class="badge warn">'+h.wakes+' wakes</span>';
  s+='</div>';
  s+='<div class="cta"><span class="badge accent">'+(needsAttention(h)?'Needs attention':'Open board')+' &rarr;</span></div>';
  s+='</a>';
  return s;
}

// ---- Processes ----
function pageProcesses(){
  var r=S.route, h=r.home; if(!h) return skeleton();
  var ui=uiFor(routeKey(r));
  var pending = h.inbox?h.inbox.pending:0;
  var wOk = h.watcher && h.watcher.state==='armed';
  var s='';
  s+='<div class="attn" role="group" aria-label="Processes attention">';
  s+='<div class="item '+(pending>0?'a-warn':'a-ok')+'"><span class="num">'+pending+'</span><span class="lbl2">waiting on captain</span></div>';
  s+='<div class="item '+(wOk?'a-ok':'a-err')+'"><span class="num">'+(wOk?'&#9679;':'&#9888;')+'</span><span class="lbl2">watcher '+esc(h.watcher?h.watcher.state:'?')+(h.watcher&&h.watcher.beat?' &middot; beat '+agoMs(h.watcher.beat*1000):'')+'</span></div>';
  s+='</div>';

  s+='<div class="filters" role="group" aria-label="Process filters" style="margin-bottom:12px">';
  s+=chip('all','All',ui.filter);
  s+=chip('attention','Attention',ui.filter);
  s+=chip('blocked','Blocked',ui.filter);
  s+='<a class="chip" style="margin-left:auto" href="/fleets/'+enc(S.route.fleet)+'/chat" data-link title="Watch and message this fleet\u2019s crewchief session">\uD83D\uDCAC Crewchief</a>';
  s+='</div>';

  var poolBy={}; var pools=(S.page&&S.page.pools)||[];
  for(var pi=0;pi<pools.length;pi++){ if(pools[pi].task) poolBy[pools[pi].task]=pools[pi]; }
  var rooms=(S.page&&S.page.rooms)||[];
  var roomOf={}; for(var ri=0;ri<rooms.length;ri++) roomOf[rooms[ri].family]=rooms[ri];
  var famKnown=(S.page&&S.page.families)||[];   // the ledger's ids, served by /api/processes

  // Build rows: crew tasks + verify rows (2.4) + a watcher row (file/live
  // state labelled distinctly).
  var rows=[];
  var tasks=(h.crew&&h.crew.tasks)||[];
  for(var i=0;i<tasks.length;i++){ var tk=tasks[i];
    var ps=poolBy[tk.id];
    var lt = ps&&ps.leased_at ? Date.parse(ps.leased_at) : 0;
    rows.push({ kind:'crew', id:tk.id, work:tk.kind||'task', project:tk.project||'—', state:tk.status||'', live:true,
      age: lt?agoMs(lt):'', ageVal: lt?(Date.now()-lt):-1, room: roomOf[tk.project]?tk.project:(roomOf[tk.id]?tk.id:null) });
  }
  rows = rows.concat(verifyProcessRows(h.verify));
  if(h.watcher){ var wb=h.watcher.beat?h.watcher.beat*1000:0; rows.push({ kind:'watcher', id:'watcher', work:h.watcher.detail||'', project:'—', state:h.watcher.state, live:true,
    age: wb?agoMs(wb):'', ageVal: wb?(Date.now()-wb):-1, room:null }); }

  var flt=ui.filter;
  function rowMatch(row){
    if(flt==='blocked') return isBlockedStatus(row.state);
    if(flt==='attention') return isBlockedStatus(row.state)||isWaitStatus(row.state)||(row.kind==='watcher'&&row.state!=='armed')||(row.room&&roomOf[row.room]&&(roomOf[row.room].pending||roomOf[row.room].handback));
    return true;
  }
  var shown=rows.filter(rowMatch);
  // Sortable columns (guide §4.4/§12): headers are real buttons with aria-sort,
  // and the chosen sort lives in the route UI cache so it survives polling.
  if(ui.sort){
    var dir=ui.sortDir||1;
    shown=shown.slice().sort(function(a,b){
      var av,bv;
      if(ui.sort==='age'){ av=a.ageVal; bv=b.ageVal; return (av-bv)*dir; }
      av=String(a[ui.sort]||'').toLowerCase(); bv=String(b[ui.sort]||'').toLowerCase();
      return av<bv?-1*dir:av>bv?1*dir:0;
    });
  }
  function th(key,label){
    var on=ui.sort===key; var ar=on?((ui.sortDir||1)>0?'ascending':'descending'):'none';
    var caret=on?((ui.sortDir||1)>0?' &#9652;':' &#9662;'):'';
    return '<th aria-sort="'+ar+'"><button class="sort" data-sort="'+key+'">'+esc(label)+caret+'</button></th>';
  }
  s+='<div class="tblwrap"><table class="tbl"><thead><tr>'+th('id','Role / ID')+th('work','Work')+th('project','Project')+th('state','State')+th('age','Age')+'</tr></thead><tbody>';
  if(!shown.length) s+='<tr><td colspan="5" class="muted" style="padding:16px">No matching processes.</td></tr>';
  for(var x=0;x<shown.length;x++){ var row=shown[x]; var rid=row.kind+':'+row.id; var open=!!ui.exp[rid];
    var expandable = row.kind!=='watcher';
    var stCls = isBlockedStatus(row.state)?'badge err':isWaitStatus(row.state)?'badge warn':(row.state==='armed'||row.kind==='crew')?'badge ok':'badge';
    s+='<tr'+(open?' class="exp-open"':'')+'>';
    s+='<td class="id">';
    if(expandable){ s+='<button class="rowdisc" data-exprow="'+esc(rid)+'" aria-expanded="'+(open?'true':'false')+'"><span class="caret">'+(open?'&#9662;':'&#9656;')+'</span>'+esc(row.id)+'</button>'; }
    else { s+=esc(row.id); }
    s+='</td>';
    s+='<td class="mono">'+esc(row.work)
      // Chief chat entry (room-chat slice C): a roomchief row opens its
      // family's detail - room, artifacts, and the live chief panel - right
      // here on Processes (the overlay lives in the shell, not the Board page).
      +(row.work==='roomchief'&&/-chief$/.test(row.id)?' <a class="fopen" href="/fleets/'+enc(S.route.fleet)+'/chat/'+enc(row.id.replace(/-chief$/,''))+'" data-link title="Chat with this roomchief">💬</a>':'')
      +'</td><td class="mono">'+esc(row.project)+'</td>';
    s+='<td><span class="'+stCls+'">'+esc(row.state||'—')+'</span> <span class="muted" style="font-size:11px">'+(row.live?'live':'file')+'</span></td>';
    s+='<td class="mono">'+esc(row.age||'—')+'</td></tr>';
    if(open && expandable){ s+='<tr class="exp-row"><td colspan="5">'+processExpand(row, roomOf, famKnown)+'</td></tr>'; }
  }
  s+='</tbody></table></div>';

  // Rooms with an OPEN obligation only (processes-ux): the full room list -
  // hundreds of closed rooms in a mature fleet - drowned this page; the
  // captain-facing subset is pending/handback, and the Fleets needs-captain
  // queue already carries the cross-fleet view. History stays reachable per
  // family from its Board detail.
  var openRooms=[]; for(var ori=0;ori<rooms.length;ori++){ if(rooms[ori].pending||rooms[ori].handback) openRooms.push(rooms[ori]); }
  if(openRooms.length){
    s+='<h2 style="font-size:14px;margin:18px 0 8px;color:var(--fg2)">Rooms waiting on captain &mdash; '+openRooms.length+'</h2>';
    s+=roomInbox(openRooms);
  }

  // Worktree pool
  s+='<h2 style="font-size:14px;margin:18px 0 8px;color:var(--fg2)">Worktree pool</h2>';
  s+=poolTable(pools);

  // Remote - one status line; the thread LIST is reference material, folded
  // behind a disclosure instead of a comma wall (processes-ux).
  var rem=(S.page&&S.page.remote)||{mirror:'off',channel:null,threads:[]};
  s+='<h2 style="font-size:14px;margin:18px 0 8px;color:var(--fg2)">Remote</h2>';
  s+='<div class="card"><div>mirror <b class="mono">'+esc(rem.mirror)+'</b>'+(rem.channel?' &middot; channel <span class="mono">'+esc(rem.channel)+'</span>':'')
    +' &middot; <span class="muted">'+((rem.threads&&rem.threads.length)||0)+' threads</span></div>';
  if(rem.threads&&rem.threads.length){
    var nm=[]; for(var t2=0;t2<rem.threads.length;t2++) nm.push(esc(rem.threads[t2].family));
    s+='<details style="margin-top:6px"><summary class="muted" style="cursor:pointer;font-size:12px">thread list</summary>'
      +'<div class="muted mono" style="margin-top:6px;font-size:12px">'+nm.join('<br>')+'</div></details>';
  }
  s+='</div>';
  return s;
}
function processExpand(row, roomOf, known){
  var s='<div class="expbox"><div class="mono" style="font-size:12px">'+esc(row.state||'')+'</div>';
  if(row.kind==='verify'){
    s+='<div class="muted mono" style="margin-top:6px">caller '+esc(row.caller||'—')+' &middot; family '+esc(row.room||'—')+' &middot; ref '+esc(row.ref||'—')+'</div>';
    if(row.worktree) s+='<div class="muted mono" style="margin-top:4px">worktree '+esc(row.worktree)+'</div>';
  }
  s+='<div class="lnk">';
  if(row.kind==='crew'){
    // One task is told on Processes, Board and Reports with no shared identity
    // unless the row links AT its family detail. It goes through the same
    // bun-tested normalizer the Board uses, with the ledger's own id set - and
    // is shown ONLY when the result is a family that set confirms, so an
    // incomplete set costs the affordance rather than serving a dead link.
    var fam=familyOfTaskId(row.id, known||[]);
    if(fam && (known||[]).indexOf(fam)>=0)
      s+='<a href="/fleets/'+enc(S.route.fleet)+'/board/'+enc(fam)+'" data-link>Open task &rarr;</a>';
    s+='<a href="/fleets/'+enc(S.route.fleet)+'/reports" data-link>Open reports &rarr;</a>';
  }
  s+='</div></div>';
  return s;
}
// Active gate runs are shown by ac-gate-watch (the live active-only observer),
// not the dashboard: a settled second-chief.md is an ordinary artifact browsed
// on the Reports route, and there is no dedicated dashboard gate state.
function roomInbox(rooms){
  if(!rooms.length) return '<div class="muted">no rooms</div>';
  var active=[], closed=[];
  for(var i=0;i<rooms.length;i++){ (rooms[i].pending||rooms[i].handback?active:closed).push(rooms[i]); }
  var ui=uiFor(routeKey(S.route));
  var s='';
  s+=roomRows(active);
  if(closed.length){
    var showOk=!!ui.exp['closedrooms'];
    s+='<button class="btn sm" data-disc="closedrooms" aria-expanded="'+(showOk?'true':'false')+'" style="margin:8px 0">'+(showOk?'Hide':'Show')+' '+closed.length+' closed</button>';
    if(showOk) s+=roomRows(closed);
  }
  return s;
}
function roomRows(list){
  if(!list.length) return '';
  var ui=uiFor(routeKey(S.route));
  var s='';
  for(var i=0;i<list.length;i++){ var rm=list[i]; var open=!!ui.exp['room:'+rm.family];
    var cls=(rm.pending||rm.handback)?'badge warn':'badge';
    s+='<div class="card" style="margin-bottom:8px;padding:10px 12px">';
    s+='<button class="rowdisc" data-exprow="room:'+esc(rm.family)+'" aria-expanded="'+(open?'true':'false')+'"><span class="caret">'+(open?'&#9662;':'&#9656;')+'</span>';
    s+='<span class="mono" style="color:var(--accent)">'+esc(rm.family)+'</span> <span class="'+cls+'">'+esc(rm.status)+'</span> <span class="muted" style="font-size:12px">'+esc(rm.last)+'</span></button>';
    if(open){ var ck=(S.route.home?S.route.home.path:'')+'|'+rm.family; var body=roomCache[ck];
      s+='<pre class="room">'+(body===undefined?'loading…':(body.length?esc(body.join('\\n')):'(empty)'))+'</pre>'; }
    s+='</div>';
  }
  return s;
}
function poolTable(pools){
  if(!pools.length) return '<div class="muted">no pooled worktrees</div>';
  // Idle available slots are capacity, not activity (processes-ux): the
  // monitoring view shows only slots DOING something (leased, or stuck dirty)
  // and folds the idle rest into one count behind a disclosure.
  var busy=[], idle=[];
  for(var bi=0;bi<pools.length;bi++){ (pools[bi].state==='available'?idle:busy).push(pools[bi]); }
  var ui=uiFor(routeKey(S.route));
  function rowsOf(list){
    var r='';
    for(var i=0;i<list.length;i++){ var p=list[i];
      r+='<tr><td class="mono">'+esc(p.repo)+'</td><td class="mono">'+esc(p.slot)+'</td>';
      r+='<td><span class="badge '+(p.state==='leased'?'ok':(p.state==='available'?'':'warn'))+'">'+esc(p.state)+'</span></td>';
      r+='<td class="mono">'+esc(p.task||'—')+'</td><td class="ts">'+esc(p.leased_at||'—')+'</td><td class="mono" style="font-size:11px">'+esc(p.worktree||'—')+'</td></tr>';
    }
    return r;
  }
  var showIdle=!!ui.exp['idleslots'];
  var btn=idle.length?'<button class="btn sm" data-disc="idleslots" aria-expanded="'+(showIdle?'true':'false')+'" style="margin:8px 0">'+(showIdle?'Hide':'Show')+' '+idle.length+' available slot'+(idle.length>1?'s':'')+'</button>':'';
  // Nothing active and idle folded: one quiet line + the button - no empty
  // table skeleton. The table renders only when it has rows to show.
  var rows=(busy.length?rowsOf(busy):'')+(showIdle?rowsOf(idle):'');
  if(!rows) return '<div class="muted" style="margin:4px 0 8px">No active worktrees.</div>'+btn;
  var s='<div class="tblwrap"><table class="tbl"><thead><tr><th>Repo</th><th>Slot</th><th>State</th><th>Task</th><th>Since</th><th>Worktree</th></tr></thead><tbody>';
  s+=rows;
  s+='</tbody></table></div>'+btn;
  return s;
}

// The board JOINS the existing /api/backlog (polled) with /api/reports (lazily
// cached) client-side by family id, and reuses the SAME composeFamily/parseBacklogLine
// /familyOfTaskId/deriveProgress the bun test proves. Live per-task status comes
// from the snapshot (normalized id -> family). ZERO new stored fields.
var boardArt={};                       // per-home reports cache: { ts, arts, loading }
var familyCache={}, familyLoading={};  // per "home|family" detail cache (overlay)
var boardOpenFam=null;                 // family id whose detail overlay is open
var boardArtReq=0;                      // monotonic guard: a newer inline-artifact fetch wins

// Fetch the home's artifact list once (12s TTL); a board re-render refreshes it.
function loadBoardReports(hp){
  var c=boardArt[hp];
  if(c && c.loading) return;
  if(c && c.arts && (Date.now()-(c.ts||0))<12000) return;
  boardArt[hp]={ ts:(c&&c.ts)||0, arts:(c&&c.arts)||null, loading:true };
  fetch('/api/reports?path='+enc(hp)).then(function(r){ return r.json(); }).then(function(j){
    boardArt[hp]={ ts:Date.now(), arts:(j&&j.artifacts)||[], loading:false };
    if(S.route && S.route.name==='board') renderPage();
  }).catch(function(){ boardArt[hp]={ ts:Date.now(), arts:(c&&c.arts)||[], loading:false }; });
}

// KPI strip data (ui-ux-pro-max #3): the one number the columns cannot show -
// rooms awaiting the captain - fetched from the processes route's own payload
// (rooms accounting stays ac-room.sh's, never re-derived), same 12s-TTL
// fetch-then-rerender shape as loadBoardReports above.
var boardKpiC={};
function loadBoardKpi(hp){
  var c=boardKpiC[hp];
  if(c && c.loading) return;
  if(c && c.ts && (Date.now()-c.ts)<12000) return;
  boardKpiC[hp]={ ts:(c&&c.ts)||0, pending:(c&&c.pending), loading:true };
  fetch('/api/processes?path='+enc(hp)).then(function(r){ return r.json(); }).then(function(j){
    var rooms=(j&&j.rooms)||[], n=0;
    for(var i=0;i<rooms.length;i++){ if(rooms[i].pending||rooms[i].handback) n++; }
    boardKpiC[hp]={ ts:Date.now(), pending:n, loading:false };
    if(S.route && S.route.name==='board') renderPage();
  }).catch(function(){ boardKpiC[hp]={ ts:Date.now(), pending:(c&&c.pending), loading:false }; });
}
function boardKpis(hp, b, bd, sysCount){
  loadBoardKpi(hp);
  // Tiles and the columns beneath them must agree: count CARDS, not raw
  // backlog lines - id-less lines skipped, epic children nested inside their
  // epic's card, sys panes joined into In-flight - the same rules pageBoard's
  // column loop applies (minus the view-narrowing search query).
  function cardCount(key){
    var lines=b[key]||[], n=0;
    for(var i=0;i<lines.length;i++){ var f=parseBacklogLine(lines[i]);
      if(!f.id) continue;
      if(f.epic && bd.known.indexOf(f.epic)>=0) continue;
      n++; }
    return n;
  }
  var flying=cardCount('in_flight')+sysCount;
  var pend=boardKpiC[hp]&&boardKpiC[hp].pending;
  var tiles=[
    ['in flight', String(flying), flying>0?'ok':''],
    ['queued', String(cardCount('queued')), ''],
    ['awaiting captain', pend==null?'…':String(pend), (pend>0)?'warn':''],
    ['done', String(cardCount('done')), ''],
  ];
  var s='<div class="kpis">';
  for(var i=0;i<tiles.length;i++)
    s+='<div class="kpi '+tiles[i][2]+'"><b>'+tiles[i][1]+'</b><span>'+tiles[i][0]+'</span></div>';
  return s+'</div>';
}

// Index the backlog once: known family ids (for the id normalizer), each family's
// raw line + section, and its epic children (lines carrying epic:<id>).
function boardData(b){
  var known=[], lineOf={}, secOf={}, childrenOf={};
  var buckets=[['in_flight','in_flight'],['queued','queued'],['done','done']];
  for(var bi=0;bi<buckets.length;bi++){ var key=buckets[bi][0], sec=buckets[bi][1], arr=b[key]||[];
    for(var i=0;i<arr.length;i++){ var f=parseBacklogLine(arr[i]); if(!f.id) continue;
      known.push(f.id); lineOf[f.id]=arr[i]; secOf[f.id]=sec;
      if(f.epic){ (childrenOf[f.epic]=childrenOf[f.epic]||[]).push({ id:f.id, line:arr[i], section:sec }); }
    }
  }
  return { known:known, lineOf:lineOf, secOf:secOf, childrenOf:childrenOf };
}

// Snapshot live status keyed to the bare family id (§5 join-key normalize).
function boardLive(home, known){
  var map={}, tasks=(home && home.crew && home.crew.tasks)||[];
  for(var i=0;i<tasks.length;i++){ var fam=familyOfTaskId(tasks[i].id, known); if(!(fam in map)) map[fam]=tasks[i].status||''; }
  return map;
}
// family -> the live task's RECORDED mode (state/<id>.meta via the snapshot).
// "-" and "" both mean "no mode" (roomchief/scout metas record "-").
function boardLiveModes(home, known){
  var map={}, tasks=(home && home.crew && home.crew.tasks)||[];
  for(var i=0;i<tasks.length;i++){
    var m=tasks[i].mode; if(!m||m==='-') continue;
    var fam=familyOfTaskId(tasks[i].id, known); if(!(fam in map)) map[fam]=m;
  }
  return map;
}
// The delivery-contract chip row (dashboard shows the MODES a task runs -
// captain ruling). SOLID chip (.cpin) = a token pinned on the row,
// the captain's recorded word; HOLLOW chip (.cauto) = the mode the live task
// actually runs with when the row pins none - the chief's own choice, shown
// so a wrong call is visible while it still runs. One builder, board card +
// detail + backlog row all render the same vocabulary.
function contractChips(contract, liveMode){
  var s='', toks=contractTokens(contract||''), pinnedMode=false;
  for(var i=0;i<toks.length;i++){
    if(toks[i].k==='mode') pinnedMode=true;
    s+='<span class="chipm cpin" title="pinned on the backlog row (captain-recorded)">'+esc(toks[i].k)+':'+esc(toks[i].v)+'</span>';
  }
  if(!pinnedMode && liveMode)
    s+='<span class="chipm cauto" title="chief-chosen at intake (recorded on the brief/meta, not pinned)">mode:'+esc(liveMode)+'</span>';
  return s;
}

// A family's detail IN the page (captain: "load trong page như board"), not a
// modal over it. It rides morph's preserved-island rule: the whole detail
// carries one data-preserve key, so a poll re-render never re-diffs the
// artifact selection, the viewer's mounted iframe, or the chief terminal - the
// property the old out-of-#page overlay existed to get. The key carries the
// load state, so the skeleton IS replaced the moment the fetch lands, and
// nothing after that.
function boardDetailPage(r){
  var fam=r.fam, hp=r.home?r.home.path:'', d=familyCache[hp+'|'+fam];
  var back='<a class="bback" href="/fleets/'+enc(r.fleet)+'/board" data-link>← Board</a>';
  var body=d?familyDetailHtml(d):'<div style="padding:20px 18px">'+skeleton()+'</div>';
  return '<div class="bdetail inpage" data-preserve="fam|'+esc(fam)+'|'+(d?'1':'0')+'">'+back+body+'</div>';
}
function pageBoard(){
  var r=S.route, ui=uiFor(routeKey(r));
  if(r.fam) return boardDetailPage(r);
  if(!S.page){ return S.pageFail?stateBox('Board unavailable','Could not load the ledger. Retrying.','err'):skeleton(); }
  var b=S.page.backlog||{in_flight:[],queued:[],done:[]};
  var hp=r.home?r.home.path:'';
  loadBoardReports(hp);
  var arts=(boardArt[hp]&&boardArt[hp].arts)||[];
  var bd=boardData(b);
  var live=boardLive(r.home, bd.known);
  var liveModes=boardLiveModes(r.home, bd.known);
  var q=(ui.query||'').toLowerCase();
  var hideDone=boardHideDone();
  // Live system/paned tasks (board-live-panes): panes running with a meta but no
  // backlog row, joined into In Flight and deduped by family against its cards.
  var inflightIds=[]; var ifl=b.in_flight||[];
  for(var ii=0;ii<ifl.length;ii++){ var iff=parseBacklogLine(ifl[ii]); if(iff.id) inflightIds.push(iff.id); }
  var sysPanes=boardSystemPanes(r.home, bd.known, inflightIds);
  // Column order (board-monitor): In flight FIRST - the monitoring question
  // is what runs NOW; what waits comes second, what landed last.
  var cols=[['in_flight','flight','In flight'],['queued','queued','Queued'],['done','done','Done']];
  var s=boardKpis(hp, b, bd, sysPanes.length);
  s+='<div class="filters" style="margin-bottom:14px">'
    +'<input class="search-in" type="search" data-list-search placeholder="Filter tasks…" aria-label="Filter tasks" autocomplete="off" spellcheck="false">'
    +'<button class="btoggle" type="button" data-board-hidedone aria-pressed="'+(hideDone?'true':'false')+'"><span class="sw" aria-hidden="true"></span>Hide Done</button>'
    +'</div>';
  s+='<div class="board'+(hideDone?' hidden-done':'')+'">';
  for(var c=0;c<cols.length;c++){ var key=cols[c][0], cls=cols[c][1], label=cols[c][2];
    if(key==='done' && hideDone) continue;                    // hidden column: drop it, remaining 2 widen
    var lines=b[key]||[], cards='', shown=0;
    for(var i=0;i<lines.length;i++){ var f=parseBacklogLine(lines[i]); if(!f.id) continue;
      if(f.epic && bd.known.indexOf(f.epic)>=0) continue;    // nests inside its epic card (unless the epic has no card -> show standalone)
      if(q && lines[i].toLowerCase().indexOf(q)<0) continue;
      shown++; cards+=boardCard(f, lines[i], key, arts, bd, live[f.id], liveModes[f.id]);
    }
    if(key==='in_flight'){ for(var sp=0;sp<sysPanes.length;sp++){ var pn=sysPanes[sp];
      if(q && (pn.id+' '+pn.kind+' '+pn.status).toLowerCase().indexOf(q)<0) continue;
      shown++; cards+=boardSysCard(pn); } }
    // Eye on the Done header hides the column (same toggle as the toolbar switch).
    var eye=key==='done'?' <button class="eye" type="button" data-board-hidedone title="Hide Done column" aria-label="Hide Done column">👁</button>':'';
    s+='<div class="bcol '+cls+'"><div class="bch"><span class="bar"></span>'+esc(label)+'<span class="cnt">'+shown+'</span>'+eye+'</div>';
    var bempty=q?'No tasks match the filter'
      :(key==='queued'?'Nothing queued — mint work with /brainstorm or an order'
      :key==='in_flight'?'Nothing in flight — spawn a READY queued row to start'
      :'Nothing landed yet');
    s+=(cards||'<div class="bempty">'+bempty+'</div>')+'</div>';
  }
  return s+'</div>';
}
// Hide-Done is a client-only view pref, persisted so it survives reload.
function boardHideDone(){ try{ return localStorage.getItem('ac_dash_hidedone')==='1'; }catch(e){ return false; } }
function toggleHideDone(){ var v=!boardHideDone(); try{ localStorage.setItem('ac_dash_hidedone', v?'1':'0'); }catch(e){} renderPage(); }

// Per-state icon + .badge modifier for the epic story sub-list (§ boardCard
// below) - STATIC presentational lookup, not logic that can lie again (the
// state ITSELF is derived by the bun-tested storyState, not here).
var STORY_ICON={done:'✓',in_flight:'●',queued:'○',failed:'✗',abandoned:'⊘'};
var STORY_BADGE={done:'ok',in_flight:'accent',queued:'',failed:'err',abandoned:'stale'};
function boardCard(f, line, sectionKey, arts, bd, liveStatus, liveMode){
  var d=composeFamily({ family:f.id, line:line, section:sectionKey, project:'', artifacts:arts, roomEntries:[], children:(bd.childrenOf[f.id]||[]), knowledgeRepos:[], learningsCiteFamily:false });
  // A standalone (non-epic) family's own card carried no state marker at all,
  // so a [failed]/[abandoned] row was indistinguishable from a real success
  // at the board's top level (same-done-miscount-in-three-more-surfaces). An
  // epic's own line never matches (its head token is [EPIC], not [failed]/
  // [abandoned]) and already has honest rollup+chips, so this reuses the same
  // STORY_ICON/STORY_BADGE vocabulary for free rather than inventing a shape.
  // d.state is composeFamily's own storyState derivation - never re-derived
  // here (no second marker parser).
  var termBadge=(d.state==='failed'||d.state==='abandoned')?' <span class="badge '+STORY_BADGE[d.state]+'" title="'+d.state+'">'+STORY_ICON[d.state]+' '+d.state.toUpperCase()+'</span>':'';
  var badges=(d.isEpic?' <span class="badgeb epic">EPIC</span>':'')+(d.pr?' <span class="badgeb pr">PR</span>':'')+termBadge;
  var chips=''; for(var i=0;i<d.stages.length;i++){ var st=d.stages[i]; chips+='<span class="chipm '+(st.report?'g':'a')+'">'+(st.report?'✓ ':'')+esc(st.stage)+'</span>'; }
  // The bar's FILL is a visual claim too, same as the badge above it: a full
  // green fill for a failed/abandoned family asserts success just as loudly
  // as the old "done" label did (same-done-miscount-in-three-more-surfaces).
  // Same d.state, same err/stale vocabulary as the badge - never re-derived.
  var barCls=d.state==='failed'?'err':(d.state==='abandoned'?'stale':'');
  var prog=d.progress.pct>0?'<div class="bprog"><i class="'+barCls+'" style="width:'+d.progress.pct+'%"></i></div>':'';
  var right = liveStatus ? '<span class="chipm a live">'+esc(liveStatus)+'</span>' : '<span class="live" style="margin-left:auto;color:var(--muted);font-size:10.5px">'+esc(d.progress.label)+'</span>';
  var roll=d.rollup?'<div class="broll">rollup '+d.rollup.done+'/'+d.rollup.total+' done</div>':'';
  var subs='';
  if(d.rollup && d.children.length){
    var raw=bd.childrenOf[f.id]||[];
    subs='<div class="bsubs">';
    for(var k=0;k<d.children.length;k++){
      var ch=d.children[k];
      var state=storyState(raw[k]?raw[k].line:'', ch.section);
      var cls=STORY_BADGE[state]?'badge '+STORY_BADGE[state]:'badge';
      subs+='<span class="'+cls+'" title="'+esc(ch.id)+'">'+STORY_ICON[state]+' '+esc(ch.id)+'</span>';
    }
    subs+='</div>';
  }
  // A LINK, so the detail is reachable by url, middle-click and back button -
  // it was a button only because the detail used to be a modal.
  var cchips=contractChips(d.contract, liveMode);
  return '<a class="bcard st-'+d.state+'" href="/fleets/'+enc(currentFleet())+'/board/'+enc(f.id)+'" data-link>'
    +'<div class="cid">'+esc(f.id)+badges+'</div>'
    +'<div class="ct">'+esc(d.text||f.id)+'</div>'
    +(cchips?'<div class="brow">'+cchips+'</div>':'')
    +(chips?'<div class="brow">'+chips+'</div>':'')
    +prog
    +'<div class="brow"><span class="chipm">repo: '+esc(d.repo||'—')+'</span>'+right+'</div>'
    +roll+subs+'</a>';
}

// A live system/paned task with no backlog row (board-live-panes): a muted,
// dashed, non-clickable card - no /api/family detail exists for machinery - with
// its kind as a badge and its live status line. Transient: gone when the pane is
// reaped and its meta disappears from the snapshot.
function boardSysCard(p){
  return '<div class="bcard sys">'
    +'<div class="cid">'+esc(p.id)+' <span class="badgeb sys">'+esc(p.kind)+'</span></div>'
    +'<div class="brow"><span class="chipm">repo: '+esc(p.project||'—')+'</span>'
    +'<span class="chipm a live">'+esc(p.status||'—')+'</span></div>'
    +'</div>';
}

// ---- Task detail, fetched from /api/family. Same FamilyDetail shape the
// composer/bun test prove. The ROUTE owns which family is open (boardOpenFam
// only mirrors it, because the chief panel's send/paste/key paths all read it),
// so opening and closing are ordinary navigation with no imperative mount. --
function boardSyncFamily(r){
  var fam=(r && r.name==='board' && r.fam) ? r.fam : null;
  if(fam!==boardOpenFam){ boardOpenFam=fam; boardArtReq++; }
  if(!fam){ chiefPollStop(); return; }
  var hp=r.home?r.home.path:''; if(!hp) return;   // home not resolved yet - the next render retries
  var ck=hp+'|'+fam;
  if(!(ck in familyCache) && !familyLoading[ck]){
    familyLoading[ck]=1;
    var done=function(j){ delete familyLoading[ck]; familyCache[ck]=j; if(boardOpenFam===fam) renderPage(); };
    fetch('/api/family?path='+enc(hp)+'&family='+enc(fam)).then(function(x){ return x.json(); })
      .then(function(j){ done(j||{error:'empty'}); })
      .catch(function(){ done({error:'failed to load'}); });
  }
  var d=familyCache[ck];
  if(d && (d.chiefLive || famHasLiveCrew(d))){ chiefNoChief=!d.chiefLive; chiefPollStart(fam); }
  else chiefPollStop();
}

// ---- Full-screen master-detail (dashboard-board-v2) ---------------------------
// The LEFT rail is a collapsible stage tree (epic: epic-level stages + a Stories
// section, each story its own repo/PR + stage tree); clicking any artifact loads
// it into the RIGHT viewer inline (md rendered, html in a sandboxed iframe) via
// the existing /api/artifact route - no navigation away. Rendered imperatively
// OUTSIDE #page, so polling never wipes the selection or the mounted iframe.
function prNum(url){ var m=String(url||'').match(/\\/pull\\/(\\d+)/); return m?('#'+m[1]):''; }
function boardArtClass(stageName, kind){ return kind==='html'?' html':(stageName==='plan'?' plan':''); }
function boardArtRow(a, stageName, title){
  return '<button class="art'+boardArtClass(stageName,a.kind)+'" type="button" data-board-art'
    +' data-art-path="'+esc(a.path)+'" data-art-kind="'+esc(a.kind)+'" data-art-title="'+esc(title)+'">'
    +fileIco(a.name)+' '+esc(a.name)+'</button>';
}
function boardStageNode(stg, titlePrefix, open){
  var arts=''; for(var i=0;i<stg.artifacts.length;i++){ var a=stg.artifacts[i]; arts+=boardArtRow(a, stg.stage, (titlePrefix||'')+stg.stage+'/'+a.name); }
  return '<div class="stage'+(open?'':' collapsed')+'">'
    +'<div class="sh" data-stage-toggle><span class="chev">▾</span>'+folderIco(open)
    +(stg.report?'<span class="tick">✓</span> ':'')+esc(stg.stage)+' <span class="n">('+stg.artifacts.length+')</span></div>'
    +'<div class="arts">'+arts+'</div></div>';
}
// The detail's three empty states were three copies of one inline style; one
// helper keeps them from drifting apart the next time one of them is edited.
function boardEmpty(text){ return '<div style="color:var(--muted);font-size:12px">'+text+'</div>'; }
// " (n)" only once there is more than one to count - the rail and the overview
// both label Repo this way.
function boardCount(n){ return n>1?' ('+n+')':''; }
function boardStageTree(stages, titlePrefix){
  if(!stages || !stages.length) return boardEmpty('— no artifacts yet —');
  // Default-expand only the last stage, and only when it is small enough to not
  // bury the rail (a big verify/qa dump stays collapsed); every stage is one click.
  var s=''; for(var i=0;i<stages.length;i++){ var open=(i===stages.length-1) && stages[i].artifacts.length<=8; s+=boardStageNode(stages[i], titlePrefix, open); } return s;
}
// Same-done-miscount-in-three-more-surfaces: the detail overlay's own Status
// text must not say "done" for a family whose own line is [failed]/
// [abandoned] - reuses composeFamily's d.state (storyState), never re-derives.
function sectionLabel(d){
  if(d.state==='failed'||d.state==='abandoned') return d.state;
  return d.section==='in_flight'?'in flight':(d.section||'—');
}
// Every repo the family touches, as chips - composeFamily's derived list, never
// the raw "multi" placeholder (board-detail-repos-prs). The one-string fallback
// keeps a family with no resolvable repo readable.
function boardRepoList(d){
  if(!d.repos || !d.repos.length) return esc(d.repo||'—');
  var s=''; for(var i=0;i<d.repos.length;i++) s+='<span class="chipm">'+esc(d.repos[i])+'</span> ';
  return s;
}
// One labelled block of the overview grid: label is markup (Repo carries its
// own count), body is already-escaped or already-built html.
function boardOvBlock(label, body, wide){ return '<div class="ovb'+(wide?' wide':'')+'"><b>'+label+'</b><p>'+body+'</p></div>'; }
// ONE PR row: number, the repo it landed in, merged/open, and who raised it -
// a multi-repo family's PRs are told apart by nothing else. The by-label is
// dropped when it would only repeat the family the detail is already showing.
function boardPrRow(p, d){
  var by=p.task||p.family; if(by===d.id||by===d.family) by='';
  return '<a class="prrow" href="'+esc(p.url)+'" target="_blank" rel="noopener" title="'+esc(p.url)+'">'
    +'<span class="prn">'+esc(prNum(p.url)||'↗')+'</span>'
    +(p.repo?'<span class="chipm">'+esc(p.repo)+'</span>':'')
    +'<span class="chipm'+(p.merged?' g':'')+'">'+(p.merged?'merged':'open')+'</span>'
    +(by?'<span class="prby">'+esc(by)+'</span>':'')
    +'</a>';
}
// A titled list block (PR, Room): the two differ only in their rows.
function boardOvList(cls, title, count, rows){
  return '<div class="'+cls+'"><b>'+title+' ('+count+')</b>'+rows+'</div>';
}
function boardOverview(d){
  var sec=sectionLabel(d);
  // The live mode for THIS family off the snapshot the client already holds -
  // the same join the board column runs (boardLiveModes), never a new fetch.
  var lm=(boardLiveModes(S.route.home, [d.family])||{})[d.family]||'';
  var cchips=contractChips(d.contract, lm);
  var rows=boardOvBlock('Description', esc(d.text||'—'), true)
    +boardOvBlock('Repo'+boardCount(d.repos?d.repos.length:0), boardRepoList(d))
    +boardOvBlock('Status', esc(sec)+(d.merged?' · merged '+esc(d.merged):'')+(d.rollup?' · rollup '+d.rollup.done+'/'+d.rollup.total:''))
    +boardOvBlock('Delivery contract', cchips||'<span class="muted">— no pins (cheap-path defaults; heavy modes would have asked the captain)</span>')
    +boardOvBlock('Stages', d.stages.length?d.stages.map(function(s){return esc(s.stage);}).join(', '):'—');
  var pr='';
  if(d.prs && d.prs.length){
    var prRows=''; for(var pi=0;pi<d.prs.length;pi++) prRows+=boardPrRow(d.prs[pi], d);
    pr=boardOvList('ovprs','PR',d.prs.length,prRows);
  }
  // The room tail only - the last 30 entries, oldest first, same as the room file.
  var room='';
  if(d.roomEntries && d.roomEntries.length){
    var reRows='';
    for(var i=Math.max(0,d.roomEntries.length-30);i<d.roomEntries.length;i++) reRows+='<div class="re">'+roomEntryHtml(d.roomEntries[i])+'</div>';
    room=boardOvList('ovroom','Room',d.roomEntries.length,reRows);
  }
  // Epic: the stories as FLAT one-line rows - id, state, text, repo, pill -
  // the main-pane view of the whole epic (epic-stories-flat); the rail keeps
  // its compact tree for artifact drilling.
  var stories='';
  if(d.rollup && d.children.length){
    var srows='';
    for(var ci=0;ci<d.children.length;ci++){ var ch=d.children[ci];
      srows+='<a class="strow" href="/fleets/'+enc(currentFleet())+'/board/'+enc(ch.id)+'" data-link>'
        +'<span class="stid">'+esc(ch.id)+'</span>'
        +'<span class="sttx">'+esc(ch.text||'')+'</span>'
        +(ch.pr?'<span class="spr" role="link" tabindex="0" data-ext="'+esc(ch.pr)+'" title="'+esc(ch.pr)+'">PR '+esc(prNum(ch.pr)||'\u2197')+'</span>'
          // Many rows record a PR as prose ('LANDED: PR #5 merged ...') with
          // no URL - still worth a (non-clickable) chip so the captain sees
          // which stories raised one (captain 2026-08-17 'k co PR?').
          :(function(){ var pm=/\bPR #(\d+)\b/.exec(ch.text||''); return pm?'<span class="spr" title="PR number recorded on the row; no URL to open">PR '+pm[1]+'</span>':''; })())
        +(ch.repo?'<span class="srepo" title="'+esc(ch.repo)+'">'+esc(ch.repo)+'</span>':'')
        +'<span class="badge '+(STORY_BADGE[ch.state]||'')+'">'+STORY_ICON[ch.state]+' '+esc(ch.state)+'</span></a>'; }
    stories=boardOvList('ovstories','Stories', d.rollup.done+'/'+d.rollup.total+' done', srows);
  }
  return '<div class="overview"><h3>'+esc(d.id)+'</h3>'
    +'<div class="ovsub">Pick an artifact on the left to view it inline here.</div>'
    +'<div class="ovrow">'+rows+'</div>'+stories+pr+room+'</div>';
}
// One room.md line -> highlighted html ('- [ts] actor> VERB: text'). The verb
// chip colors match the grammar the captain reads everywhere else.
function roomEntryHtml(line){
  var m=/^- \\[([^\\]]*)\\] ([^>]*)> (.*)$/.exec(line||'');
  if(!m) return esc(line||'');
  var body=m[3], v=/^([A-Z][A-Z-]+)(?=[ :(])/.exec(body);
  var cls={GATE:'warn',ASK:'warn','NEEDS-DECISION':'warn',DECIDED:'ok','GATE-PASSED':'ok','SELF-APPROVED':'ok',HANDBACK:'acc',PROMOTED:'acc',DEMOTED:'',TRIAGE:'acc','GATE-VERIFY':'','GATE-LOOPED':''}[v?v[1]:''];
  return '<span class="rets mono">'+esc((m[1]||'').slice(0,16))+'</span> <span class="rea mono">'+esc(m[2])+'</span> '
    +(v?'<span class="rev '+(cls||'')+'">'+esc(v[1])+'</span>'+esc(body.slice(v[1].length)):esc(body));
}
// The title bar. The id is passed in because the error shell names the family
// we TRIED to open, which is all it knows.
// No close button: the detail is a route, so leaving it is Back - the browser's
// own control, plus the ← Board link above.
function boardDetailHead(id, d){
  var stCls=!d?'':(d.state==='failed'?' err':(d.state==='abandoned'?' stale':(d.section==='queued'?' q':(d.section==='in_flight'?' f':''))));
  return '<div class="fhead"><span class="did">'+esc(id)+'</span>'
    +(d&&d.isEpic?'<span class="badgeb epic">EPIC</span>':'')
    +(d?'<span class="stt'+stCls+'">'+esc(sectionLabel(d))+(d.rollup?' · '+d.rollup.done+'/'+d.rollup.total:'')+'</span>':'')
    +'</div>';
}
// Every row is a real link: lk.path is records-relative, and /api/records serves
// repo-knowledge md files beside the five ledgers, so the knowledge rows are
// not text that merely looks clickable.
function boardLinkRows(links, fleet){
  if(!links.length) return boardEmpty('—');
  var s=''; for(var li=0;li<links.length;li++){
    var rel=String(links[li].path||'').replace(/^records\\//,'');
    s+='<a class="rlink" href="/fleets/'+enc(fleet)+'/records/'+enc(rel)+'" data-link>🔗 '+esc(links[li].label)+'</a>';
  }
  return s;
}
// The left rail: progress, the artifact tree (an epic lists its stories instead),
// the reused-knowledge links, the repo list, and the room button.
function boardDetailRail(d, fleet){
  // Progress flags the STEPS (progress-segments): one segment per FLOW stage
  // (spec/arch/design/plan/implement/qa/report - verifier and chief dirs are
  // artifacts, not steps), filled when that stage has its report. A family
  // whose flow stages carry no report yet (an in-flight direct task) falls
  // back to the % fill so the bar never reads as unloaded. Terminal tints.
  var FLOW_STAGES={spec:1,architecture:1,arch:1,design:1,plan:1,implement:1,qa:1,report:1};
  var flow=[], anyRep=false;
  for(var sg=0;sg<d.stages.length;sg++){ var st0=d.stages[sg];
    if(FLOW_STAGES[st0.stage]){ flow.push(st0); if(st0.report) anyRep=true; } }
  var segCls, segs='';
  if(flow.length && anyRep){
    segCls='prog segd';
    for(var sg2=0;sg2<flow.length;sg2++){ var st1=flow[sg2];
      segs+='<i class="'+(st1.report?(d.state==='failed'?'err':(d.state==='abandoned'?'stale':'on')):'')+'" title="'+esc(st1.stage)+(st1.report?' ✓':'')+'"></i>'; }
  } else {
    segCls='prog';
    segs='<i class="'+(d.state==='failed'?'err':(d.state==='abandoned'?'stale':''))+'" style="width:'+d.progress.pct+'%"></i>';
  }
  var s='<div class="rail">'
    +'<h4>Progress</h4><div class="'+segCls+'">'+segs+'</div><div class="plabel">'+esc(d.progress.label||'—')+'</div>';
  if(d.timeline && d.timeline.length)
    s+='<button class="tlbtn" type="button" data-board-timeline>🕑 Timeline <span class="n">('+d.timeline.length+')</span></button>';
  if(d.rollup){
    // ONE story surface (stories-merge): the overview's highlighted card list
    // is the epic's story view; the rail keeps epic-level artifacts and a
    // counted button into that list. A story's own artifacts live on its own
    // detail page (each card links there).
    s+='<h4>Epic artifacts</h4>'+boardStageTree(d.stages, '')
      +'<button class="tlbtn" type="button" data-board-overview>\u25a4 Stories <span class="n">('+d.children.length+')</span></button>';
  } else {
    s+='<h4>Stages + artifacts</h4>'+boardStageTree(d.stages, '');
  }
  s+='<h4>Linked (reused)</h4>'+boardLinkRows(d.links, fleet)
    +'<h4>Repo'+boardCount(d.repos?d.repos.length:0)+'</h4>'
    +'<div class="repotxt">'+boardRepoList(d)+'</div>';
  if(d.roomCount) s+='<button class="roombtn" type="button" data-board-room>💬 Room ('+d.roomCount+')</button>';
  return s+'</div>';
}
// The right viewer: a toolbar whose ids the artifact loader writes into, over a
// body that starts on the overview.
function boardDetailViewer(d){
  return '<div class="viewer">'
    +'<div class="vbar"><button class="btn sm" type="button" id="board-ovbtn" data-board-overview title="Back to the family overview" hidden>\u2302 Overview</button>'
    +'<span class="vpath" id="board-vpath">overview</span><span class="vkind" id="board-vkind" hidden></span>'
    +'<button class="btn sm" id="board-review-btn" type="button" data-tool-open="" data-tool-title="" hidden>Review &#9655;</button>'
    +'<a class="btn sm" id="board-review-ext" href="#" target="_blank" rel="noopener" title="open in new tab" hidden>&#8599;</a></div>'
    +'<div class="vbody" id="board-vbody">'+boardOverview(d)+'</div></div>';
}
// A family with live CREW but no roomchief (direct flow) still has panes worth
// watching - the same snapshot join the board column runs (task-terminal-mount).
function famHasLiveCrew(d){
  var lm=boardLive(S.route.home, [d.family||d.id]);
  return !!lm[d.family||d.id];
}
function familyDetailHtml(d){
  var fleet=S.route.fleet;
  if(d.error) return boardDetailHead(boardOpenFam, null)+'<div style="padding:20px 18px">'+stateBox('Detail unavailable', d.error, 'err')+'</div>';
  // Chief panel (room-chat slice A; widened by task-terminal-mount): mounted
  // for a live roomchief OR a direct-flow family with live crew panes - the
  // task view answers "what is the terminal doing" either way. Without a
  // chief the panel auto-watches the first family pane, read-only.
  var live=d.chiefLive||famHasLiveCrew(d);
  var chief=live?chiefPanelHtml(d.chiefLive?(d.id+'-chief'):(d.id+' crew')):'';
  var grip=live?'<div class="cgrip" id="chief-grip" title="Drag to resize the chief panel"></div>':'';
  return boardDetailHead(d.id, d)
    +'<div class="fbody'+(live?' haschief':'')+'"'+(live?chiefWStyle():'')+'>'
    +boardDetailRail(d, fleet)+boardDetailViewer(d)+grip+chief+'</div>';
}
// ---- Chief panel input (room-chat slice B/C) ------------------------------
// ONE live target at a time: a family overlay's roomchief, or the fleet
// crewchief drawer - opening either closes the other, so the shared ids
// (chief-term/chief-msg/...) never exist twice.
var chiefKb=false, chiefWatch='';   // ''=the chief itself; else a family pane id (read-only)
var chiefNoChief=false;             // task-terminal-mount: panel mounted for crew panes only (no roomchief tab, auto-watch)
function chatRoute(){ return S.route&&S.route.name==='chat'?S.route:null; }
function chiefFam(){ var cr=chatRoute(); if(cr) return cr.fam||null; return boardOpenFam; }
function chiefLoadTabs(){
  var hp=S.route.home?S.route.home.path:''; var fam=chiefFam();
  var box=el('chief-tabs'); if(!box) return;
  if(!hp||!fam){ box.innerHTML=''; return; }
  fetch('/api/room/panes?path='+enc(hp)+'&family='+enc(fam)).then(function(r){ return r.json(); }).then(function(j){
    var box2=el('chief-tabs'); if(!box2) return;
    var panes=(j&&j.panes)||[];
    if(!panes.length){ box2.innerHTML=''; return; }
    // No roomchief: there is no chief tab to offer, and an empty watch would
    // poll a pane that cannot exist - pick the first crew pane instead
    // (task-terminal-mount). setWatch re-runs this loader with watch set.
    if(chiefNoChief && chiefWatch===''){ chiefSetWatch(panes[0].id); return; }
    var h=chiefNoChief?'':'<button type="button" class="ct'+(chiefWatch===''?' on':'')+'" data-chief-watch=""><span class="dot"></span>chief</button>';
    for(var i=0;i<panes.length;i++){ var pn=panes[i];
      var lbl = pn.id===fam ? (pn.kind||'task')
              : (pn.id.indexOf(fam+'-')===0 ? pn.id.slice(fam.length+1) : pn.id);
      var kb = (lbl!==pn.kind && pn.kind) ? ' <span class="k">'+esc(pn.kind)+'</span>' : '';
      h+='<button type="button" class="ct'+(chiefWatch===pn.id?' on':'')+'" data-chief-watch="'+esc(pn.id)+'" title="'+esc(pn.id)+' ('+esc(pn.kind)+') — read-only view">'+esc(lbl)+kb+'</button>';
    }
    box2.innerHTML=h;
  }).catch(function(){});
}
function chiefSetWatch(id){
  chiefWatch=id||'';
  try{ if(chiefWatch) localStorage.setItem(chiefWatchKey(chiefCur), chiefWatch); else localStorage.removeItem(chiefWatchKey(chiefCur)); }catch(e){}
  var ro=chiefWatch!=='';
  var tt=el('chief-title'); if(tt) tt.textContent = ro ? chiefWatch : (tt.getAttribute('data-t')||'');
  var ta=el('chief-msg'); if(ta) ta.placeholder = ro ? 'Message '+chiefWatch+'… (Enter to send)' : 'Message the chief… (Enter to send, Shift+Enter for newline)';
  var t=el('chief-term'); if(t) t.innerHTML='';
  var st=el('chief-state'); if(st) st.textContent='connecting…';
  chiefLoadTabs();
  var tgt=chiefCur; chiefPollStop(); chiefPollStart(tgt, true); // re-arm keeping the new watch (stream reconnects with the watch param)
}
function chiefTargetQ(){
  var cr=chatRoute();
  if(cr) return cr.fam?'&family='+enc(cr.fam):'&fleet=1';
  if(boardOpenFam!==null) return '&family='+enc(boardOpenFam);
  return null;
}
function chiefApi(pathname, body, isJson){
  var hp=S.route.home?S.route.home.path:''; var tq=chiefTargetQ();
  if(!hp||tq===null) return Promise.reject();
  return fetch(pathname+'?path='+enc(hp)+tq+(chiefWatch?'&watch='+enc(chiefWatch):''),
    { method:'POST', headers:{'content-type': isJson?'application/json':'text/plain'}, body:body });
}
function chiefPanelHtml(title, backHref){
  return '<div class="chiefp"><div class="cbar">'
    +(backHref?'<a class="cback" href="'+esc(backHref)+'" data-link title="Back to Processes">←</a>':'')
    +'<b id="chief-title" data-t="'+esc(title)+'">'+esc(title)+'</b><span id="chief-state">connecting…</span>'
    +'<button type="button" id="chief-compose" class="cbtn" aria-pressed="'+(chiefComposerOpen?'true':'false')+'" title="Composer: draft a longer message and send it whole (ac-send)">✉ Compose</button>'
    +'</div>'
    +'<div class="ctabs" id="chief-tabs"></div>'
    +'<pre class="cterm" id="chief-term" aria-label="Live chief terminal"></pre>'
    +'<input id="chief-ime" autocomplete="off" spellcheck="false" aria-label="Type-through input" style="position:absolute;left:-9999px;width:2px;height:2px;opacity:0">'
    +'<div class="csend"'+(chiefComposerOpen?'':' style="display:none"')+'><textarea id="chief-msg" rows="2" placeholder="Message the chief… (Enter to send, Shift+Enter for newline)"></textarea>'
    +'<button type="button" class="btn sm primary" id="chief-send">Send</button></div>'
    +'<div class="cnote" id="chief-note"></div></div>';
}
// Terminal page (top-level /terminal tab): iframe the native /term-frame
// bridge /api/term/status points at; poll status until it serves, then mount
// ONCE (the iframe is a keyed island - re-rendering it would kill the live
// session). Nothing starts until this page is opened: the PTY spawns on the
// iframe's websocket connect and dies with it when the page is left.
var termUrl=null, termWhy='checking…', termT=null;
function pageTerm(){
  if(termUrl){
    var open='<a class="termopen" href="/term" target="_blank" rel="noopener" title="open in its own page">&#8599;</a>';
    return '<div class="termpage">'+open+'<iframe src="'+esc(termUrl)+'" title="herdr terminal"></iframe></div>';
  }
  return '<div class="termpage"><div class="cdead">'+esc(termWhy)+'</div></div>';
}
function termFit(){
  // Fill the viewport exactly: the old fixed calc guessed the header height
  // and left a dead band under the frame - measure the page's real offset
  // instead, every render and resize (the iframe is a keyed island, so a
  // height change never remounts the live session). Full-bleed, so the frame
  // runs to the viewport floor - no gutter left under it either.
  var tp=document.querySelector('.termpage, .chatpage'); if(!tp) return;
  var r=tp.getBoundingClientRect();
  tp.style.height=Math.max(420, Math.floor(window.innerHeight - r.top) - 1)+'px';
}
// Paint the terminal frame in the page's OWN theme (captain: nền webterm phải
// khớp nền theme). The frame is same-origin, so this is a direct call into the
// function it exposes - never a remount, which would kill the herdr client.
// Deduped on the pair, so the per-poll renderPage never repaints for nothing.
// The mapping itself lives in the shared termThemeCore (interpolated below) -
// one implementation for this tab AND the standalone /term page.
${termThemeCore.toString()}
var termBg='';
function termTheme(){
  var f=document.querySelector('.termpage iframe'); if(!f) return;
  var r=termThemeCore(getComputedStyle(document.documentElement));
  if(!r || r.sig===termBg) return;
  var w=f.contentWindow;
  if(w && typeof w.acSetTheme==='function'){ w.acSetTheme(r.theme); termBg=r.sig; }
}
function termPoll(){
  // Top-level /terminal has no fleet in the route: herdr is one session
  // machine-wide, so any known home path satisfies the server's gate.
  var hp=S.route&&S.route.home?S.route.home.path:'';
  if(!hp){ var th=fleetByName(S.snap, currentFleet()); hp=th?th.path:''; }
  if(!hp) return;
  fetch('/api/term/status?path='+enc(hp)).then(function(r){ return r.json(); }).then(function(j){
    if(!S.route||S.route.name!=='term'){ clearTimeout(termT); termT=null; return; }
    if(j.running&&j.url){ if(termUrl!==j.url){ termUrl=j.url; renderPage(); } return; }
    termUrl=null; termWhy=j.why||j.error||'unavailable'; renderPage();
    termT=setTimeout(termPoll, 1500);
  }).catch(function(){ termT=setTimeout(termPoll, 3000); });
}

// The dedicated chat tab (room-chat slice C, captain: "tab riêng"): a full
// page whose whole body is the chief panel; /fleets/:fleet/chat targets the
// crewchief, /fleets/:fleet/chat/:family that family's roomchief.
function pageChat(){
  var cr=chatRoute(); if(!cr) return '';
  var title=cr.fam?cr.fam+'-chief':'crewchief · '+(cr.fleet||'');
  return '<div class="chatpage">'+chiefPanelHtml(title, '/fleets/'+enc(cr.fleet)+'/processes')+'</div>';
}
function chiefNote(t, err){ var n=el('chief-note'); if(n){ n.textContent=t||''; n.className='cnote'+(err?' err':''); } }
function chiefSendMsg(){
  var ta=el('chief-msg'); if(!ta) return;
  var msg=(ta.value||'').trim(); if(!msg) return;
  var btn=el('chief-send'); if(btn) btn.disabled=true;
  chiefNote('sending…');
  chiefApi('/api/room/send', msg).then(function(r){ return r.json().then(function(j){ return {ok:r.ok, j:j}; }); })
    .then(function(res){
      if(btn) btn.disabled=false;
      if(res.ok){ ta.value=''; chiefNote('sent — the chief answers in its pane and posts receipts to the room'); chiefPoke(); }
      else chiefNote('refused: '+((res.j&&res.j.error)||'failed')+(res.j&&res.j.detail?' — '+res.j.detail:''), true);
    })
    .catch(function(){ if(btn) btn.disabled=false; chiefNote('unreachable — nothing sent', true); });
}
function chiefInput(body){
  if(chiefSock && chiefSock.readyState===1){ chiefSock.send(JSON.stringify(body)); return; }
  chiefApi('/api/room/input', JSON.stringify(body), true).then(chiefPoke).catch(function(){});
}
function chiefKey(k){ chiefInput({key:k}); }
function chiefChar(c){ chiefInput({text:c}); }
function chiefText(v){ if(!v) return; chiefInput(v.length===1?{text:v}:{paste:v}); }
// IME-correct type-through: printable keys land in the hidden input, whose
// input/compositionend events deliver COMPOSED text (Vietnamese telex commits
// one accented char, not its raw keystrokes). Named keys never compose and
// keep the direct send-keys path.
addEventListener('input', function(e){
  var t=e.target; if(!t||t.id!=='chief-ime'||e.isComposing) return;
  var v=t.value; if(v){ t.value=''; chiefText(v); }
});
addEventListener('compositionend', function(e){
  var t=e.target; if(!t||t.id!=='chief-ime') return;
  var v=t.value; if(v){ t.value=''; chiefText(v); }
});
addEventListener('paste', function(e){
  if(boardOpenFam===null && !chatRoute()) return;
  // Image paste works from ANY focus (composer included): the image is saved
  // under the family's data dir and its path typed into the pane.
  var items=(e.clipboardData&&e.clipboardData.items)||[];
  for(var pi=0;pi<items.length;pi++){
    if(items[pi].type && items[pi].type.indexOf('image/')===0){
      e.preventDefault();
      var f=items[pi].getAsFile(); if(!f) return;
      chiefNote('uploading image…');
      f.arrayBuffer().then(function(buf){
        var hp=S.route.home?S.route.home.path:''; var tq=chiefTargetQ();
        if(!hp||tq===null) return;
        return fetch('/api/room/attach?path='+enc(hp)+tq+(chiefWatch?'&watch='+enc(chiefWatch):''),
          { method:'POST', headers:{'content-type': f.type}, body: buf })
          .then(function(r){ return r.json(); })
          .then(function(j){
            if(j.ok) chiefNote('ảnh đã lưu + path đã gõ vào pane — thêm lời nhắn rồi Enter để gửi');
            else chiefNote('refused: '+(j.error||'attach failed'), true);
          });
      }).catch(function(){ chiefNote('unreachable — image not sent', true); });
      return;
    }
  }
  if(!chiefKb) return;
  var t=e.target;
  if(t && t.id!=='chief-ime' && (t.id==='chief-msg' || t.tagName==='INPUT' || t.tagName==='TEXTAREA')) return;
  var txt=(e.clipboardData&&e.clipboardData.getData('text'))||'';
  if(txt){ e.preventDefault(); if(t&&t.id==='chief-ime') t.value=''; chiefText(txt.replace(/\\r/g,'')); }
});
function chiefKbToggle(){
  chiefKb=!chiefKb;
  var b=el('chief-kb'); if(b){ b.setAttribute('aria-pressed', chiefKb?'true':'false'); b.classList.toggle('on', chiefKb); }
  chiefNote(chiefKb?'typing straight into the pane (keys · Vietnamese IME · Ctrl+V images) — open ✉ Compose to stop':'');
  var im=el('chief-ime'); if(im){ if(chiefKb) im.focus(); else im.blur(); }
  chiefRearmCadence();   // 500ms echo while typing, 2s otherwise
}
// Type-through capture: alive only while the toggle is on AND the overlay is
// open; the composer textarea keeps its own keys (it is for whole messages).
addEventListener('keydown', function(e){
  var t=e.target;
  // Composer: Enter sends, Shift+Enter stays a newline.
  if(t && t.id==='chief-msg'){ if(chiefKb && e.key!=='Enter'){ chiefKb=false; chiefNote(''); } if(e.key==='Enter' && !e.shiftKey){ e.preventDefault(); chiefSendMsg(); return; } }
  if(!chiefKb || (boardOpenFam===null && !chatRoute())) return;
  var inIme = t && t.id==='chief-ime';
  if(!inIme && t && (t.id==='chief-msg' || t.tagName==='INPUT' || t.tagName==='TEXTAREA')) return;
  var map={ArrowUp:'up',ArrowDown:'down',ArrowLeft:'left',ArrowRight:'right',Enter:'enter',Escape:'esc',Tab:e.shiftKey?'shift+tab':'tab',Backspace:'backspace',PageUp:'pageup',PageDown:'pagedown'};
  if(e.ctrlKey && e.key==='c'){ e.preventDefault(); chiefKey('ctrl+c'); return; }
  if(e.ctrlKey && e.key==='u'){ e.preventDefault(); chiefKey('ctrl+u'); return; }
  if(e.ctrlKey && !e.metaKey && e.key==='v'){ e.preventDefault(); chiefKey('ctrl+v'); return; }
  if(map[e.key]){
    if(inIme && e.key==='Backspace' && t.value){ return; }   // editing the IME buffer, not the pane
    e.preventDefault(); chiefKey(map[e.key]); return;
  }
  if(e.key===' ' && !inIme){ e.preventDefault(); chiefKey('space'); return; }
  if(inIme) return;   // printable keys flow into the hidden input -> composed text
  if(e.key.length===1 && !e.metaKey && !e.ctrlKey && !e.altKey){ e.preventDefault(); chiefChar(e.key); }
}, true);
// Poll loop for the chief panel: alive only while the overlay shows a family
// with a live chief; boardSyncFamily arms and disarms it. Autoscroll pins
// to the bottom unless the captain scrolled up to read history.
function chiefWStyle(){
  var w=0; try{ w=Number(localStorage.getItem('ac_dash_chiefw'))||0; }catch(e){}
  return w?' style="--chiefw:'+Math.round(w)+'px"':'';
}
var chiefDragOn=false;
addEventListener('mousedown', function(e){
  var g=e.target && e.target.closest && e.target.closest('#chief-grip'); if(!g) return;
  e.preventDefault(); chiefDragOn=true; document.body.style.cursor='col-resize'; document.body.style.userSelect='none';
});
addEventListener('mousemove', function(e){
  if(!chiefDragOn) return;
  var w=Math.min(Math.max(window.innerWidth - e.clientX, 320), Math.round(window.innerWidth*0.75));
  var fb=document.querySelector('.bdetail .fbody.haschief'); if(fb) fb.style.setProperty('--chiefw', w+'px');
});
addEventListener('mouseup', function(){
  if(!chiefDragOn) return;
  chiefDragOn=false; document.body.style.cursor=''; document.body.style.userSelect='';
  var fb=document.querySelector('.bdetail .fbody.haschief');
  var w=fb?fb.style.getPropertyValue('--chiefw'):'';
  try{ if(w) localStorage.setItem('ac_dash_chiefw', parseInt(w,10)); }catch(e){}
});
var chiefTimer=null, chiefCur=null, chiefTickFn=null, chiefLines=400, chiefMore=false, chiefPokeT=null;
var chiefSock=null, chiefSockGen=0, chiefComposerOpen=false;
function chiefComposeToggle(){
  chiefComposerOpen=!chiefComposerOpen;
  var cs=document.querySelector('.chiefp .csend'); if(cs) cs.style.display=chiefComposerOpen?'':'none';
  var b=el('chief-compose'); if(b) b.setAttribute('aria-pressed', chiefComposerOpen?'true':'false');
  if(chiefComposerOpen){ chiefKb=false; chiefNote(''); var ta=el('chief-msg'); if(ta) try{ ta.focus(); }catch(e){} }
}
function chiefFrame(j){
  var t=el('chief-term'), st=el('chief-state'); if(!t||!st) return;
  if(j.inputError){ chiefNote('refused: '+j.inputError, true); return; }
  if(!j.live){ st.textContent=j.why||'not live'; return; }
  st.textContent=(j.readonly?'live · watching '+chiefWatch:'live · type here')+' · stream';
  if(t._h===j.html) return;
  var pinned = t.scrollTop + t.clientHeight >= t.scrollHeight - 8;
  var fromBottom = t.scrollHeight - t.scrollTop;
  t._h=j.html;
  // Box-drawing separator rows are drawn at the pane's own column width;
  // wider than the panel they would soft-wrap and leave a stub line under
  // each rule - keep every run on one line, clipped at the panel edge.
  t.innerHTML=(j.html||'').replace(/─{20,}/g, '<span class="csep">$&</span>');
  // Auto-fit (no horizontal scroll): the pane's column count is the width of
  // its box-drawing separator rows; size the font so exactly that many
  // monospace cells fit the panel, and let longer prose lines soft-wrap.
  var cols=0, runs=(t.textContent||'').match(/─{20,}/g)||[];
  for(var li2=0;li2<runs.length;li2++){ if(runs[li2].length>cols) cols=runs[li2].length; }
  cols=Math.min(cols, 240);
  if(!cols) cols=t._cols||100;
  if(cols!==t._cols || Math.abs((t._w||0)-t.clientWidth)>4){
    t._cols=cols; t._w=t.clientWidth;
    // Ceiling 12px = the web terminal's own size: fit only ever SHRINKS to
    // avoid horizontal overflow, never grows the snapshot past the terminal.
    var px=Math.max(9.5, Math.min(12, (t.clientWidth-26)/(cols*0.602)));
    t.style.fontSize=px.toFixed(2)+'px';
  }
  if(pinned) t.scrollTop=t.scrollHeight;
  else t.scrollTop=Math.max(0, t.scrollHeight - fromBottom);
}
function chiefStreamStart(target){
  var hp=S.route.home?S.route.home.path:''; if(!hp) return false;
  var q=(target===true)?'&fleet=1':'&family='+enc(target);
  if(chiefWatch) q+='&watch='+enc(chiefWatch);
  var g=++chiefSockGen;
  try{ chiefSock=new WebSocket('ws://'+location.host+'/api/room/stream?path='+enc(hp)+q); }
  catch(e){ chiefSock=null; return false; }
  chiefSock.onmessage=function(e){ if(g!==chiefSockGen) return; try{ chiefFrame(JSON.parse(e.data)); }catch(err){} };
  chiefSock.onclose=function(){ if(g!==chiefSockGen) return; chiefSock=null;
    if(chiefCur!==null) chiefPollStartPoll(chiefCur);   // stream gone: interval poll takes over
  };
  return true;
}
function chiefStreamStop(){ chiefSockGen++; if(chiefSock){ try{ chiefSock.close(); }catch(e){} chiefSock=null; } }
function chiefCadence(){ return chiefKb?500:2000; }
function chiefRearmCadence(){ if(!chiefTimer||!chiefTickFn) return; clearInterval(chiefTimer); chiefTimer=setInterval(chiefTickFn, chiefCadence()); }
// One immediate (debounced) refresh right after an input lands: the echo
// arrives in ~150ms instead of at the next tick.
function chiefPoke(){ if(!chiefTickFn) return; clearTimeout(chiefPokeT); chiefPokeT=setTimeout(function(){ if(chiefTickFn) chiefTickFn(); },150); }
function chiefPollStop(){ chiefStreamStop(); if(chiefTimer){ clearInterval(chiefTimer); chiefTimer=null; } chiefCur=null; chiefTickFn=null; }
// The picked watch tab survives reloads and route round-trips per family
// (watch-tab-persist): a browser refresh used to snap 'ship' back to 'chief'.
function chiefWatchKey(target){
  var hp=S.route.home?S.route.home.path:'';
  return 'ac_dash_watch:'+hp+'|'+(target===true?'fleet':String(target));
}
function chiefPollStart(target, keepWatch){
  if((chiefSock||chiefTimer) && chiefCur===target) return;   // renderPage re-arms every poll tick; same target keeps its transport
  chiefPollStop(); chiefCur=target; chiefLines=400;
  if(!keepWatch){ try{ chiefWatch=localStorage.getItem(chiefWatchKey(target))||''; }catch(e){ chiefWatch=''; } }   // a NEW target restores its remembered pick
  if(target!==true) chiefLoadTabs();   // family targets get the linked-pane chips
  if(chiefStreamStart(target)) return;   // ws push (250ms server-side); the loop below is the fallback
  chiefPollStartPoll(target);
}
function chiefPollStartPoll(target){
  var hp=S.route.home?S.route.home.path:''; if(!hp) return;
  var q=function(){ return ((target===true)?'&fleet=1':'&family='+enc(target)) + (chiefWatch?'&watch='+enc(chiefWatch):''); };
  var alive=function(){
    var cr=chatRoute();
    if(cr) return target===true ? !cr.fam : cr.fam===target;
    return boardOpenFam===target;
  };
  var tick=function(){
    if(!alive()){ chiefPollStop(); return; }
    fetch('/api/room/pane?path='+enc(hp)+q()+'&lines='+chiefLines).then(function(r){ return r.json(); }).then(function(j){
      if(!alive()) return;
      chiefFrame(j);
    }).catch(function(){ var st=el('chief-state'); if(st) st.textContent='unreachable'; });
  };
  chiefTickFn=tick;
  tick();
  chiefTimer=setInterval(tick, chiefCadence());
}
// Reaching the top of the terminal loads older scrollback (up to 3000 lines).
addEventListener('scroll', function(e){
  var t=e.target; if(!t||t.id!=='chief-term') return;
  if(t.scrollTop<40 && !chiefMore && chiefLines<3000){
    chiefMore=true; chiefLines=Math.min(3000, chiefLines+600);
    if(chiefSock && chiefSock.readyState===1) chiefSock.send(JSON.stringify({lines:chiefLines}));
    else chiefPoke();
    setTimeout(function(){ chiefMore=false; }, 800);
  }
}, true);
function fmtDur(ms){
  if(!ms || ms<0) return '';
  var s=Math.round(ms/1000);
  if(s<60) return s+'s';
  var m=Math.floor(s/60), rs=s%60;
  if(m<60) return m+'m'+(rs?' '+rs+'s':'');
  var h=Math.floor(m/60), rm=m%60;
  if(h<24) return h+'h'+(rm?' '+rm+'m':'');
  var dd=Math.floor(h/24), rh=h%24;
  return dd+'d'+(rh?' '+rh+'h':'');
}
// Render the selected task's durable lifecycle timeline (task-timeline) into the
// right viewer pane - vertical, chronological, each event carrying its wall-clock
// time AND the delta from the previous event, so per-step duration reads at a
// glance. Data is already in d.timeline (parseTimeline, server-side); no fetch.
// Same Review affordance the Reports viewer offers (:viewerHtml), driven by
// the CURRENTLY selected artifact's path - hidden on overview/timeline and on
// any kind reviewableArtifact rejects, so the button never points at a file
// /review cannot render.
function boardSetReviewBtn(path){
  var btn=el('board-review-btn'), ext=el('board-review-ext'); if(!btn||!ext) return;
  if(path && reviewableArtifact(path)){
    var hp=S.route.home?S.route.home.path:'', rvUrl='/review?path='+enc(hp)+'&file='+enc(path);
    btn.hidden=false; btn.setAttribute('data-tool-open', rvUrl); btn.setAttribute('data-tool-title', 'review · '+path.split('/').pop());
    ext.hidden=false; ext.href=rvUrl;
  } else {
    btn.hidden=true; ext.hidden=true;
  }
}
// Back to the overview from any viewer state - room, timeline, artifact
// (viewer-overview-return): the same reset every renderer starts with.
function boardShowOverview(){
  var box=document.querySelector('.bdetail'); if(!box) return;
  var prev=box.querySelector('.art.on'); if(prev) prev.classList.remove('on');
  var hp=S.route.home?S.route.home.path:'', d=familyCache[hp+'|'+boardOpenFam];
  var vpath=el('board-vpath'), vkind=el('board-vkind'), vbody=el('board-vbody');
  if(vpath) vpath.textContent='overview';
  if(vkind) vkind.hidden=true;
  var ob0=el('board-ovbtn'); if(ob0) ob0.hidden=true;   // no button while already home
  boardSetReviewBtn(null);
  if(vbody && d) vbody.innerHTML=boardOverview(d);
}
// Room in the viewer (room-in-viewer): the rail's Room button used to jump to
// Processes, which no longer lists closed rooms - the record belongs HERE,
// rendered with the same verb-chip line renderer the overview tail uses.
function boardShowRoom(){
  var box=document.querySelector('.bdetail'); if(!box) return;
  var prev=box.querySelector('.art.on'); if(prev) prev.classList.remove('on');
  var hp=S.route.home?S.route.home.path:'', d=familyCache[hp+'|'+boardOpenFam];
  var evs=(d&&d.roomEntries)||[];
  var vpath=el('board-vpath'), vkind=el('board-vkind'), vbody=el('board-vbody');
  if(vpath) vpath.textContent='room';
  if(vkind){ vkind.hidden=true; }
  var ob1=el('board-ovbtn'); if(ob1) ob1.hidden=false;
  boardSetReviewBtn(null);
  if(!vbody) return;
  if(!evs.length){ vbody.innerHTML=stateBox('Empty room','no entries recorded yet',''); return; }
  var s='<div class="ovroom" style="margin:14px 0 0"><b>Room ('+evs.length+')</b>';
  for(var i=0;i<evs.length;i++) s+='<div class="re">'+roomEntryHtml(evs[i])+'</div>';
  s+='</div>';
  vbody.innerHTML=s;
}
function boardShowTimeline(){
  var box=document.querySelector('.bdetail'); if(!box) return;   // the detail lives in #page now, not under a modal id
  var prev=box.querySelector('.art.on'); if(prev) prev.classList.remove('on');
  var hp=S.route.home?S.route.home.path:'', d=familyCache[hp+'|'+boardOpenFam];
  var evs=(d&&d.timeline)||[];
  var vpath=el('board-vpath'), vkind=el('board-vkind'), vbody=el('board-vbody');
  if(vpath) vpath.textContent='timeline';
  if(vkind){ vkind.hidden=true; }
  var ob2=el('board-ovbtn'); if(ob2) ob2.hidden=false;
  boardSetReviewBtn(null);
  if(!vbody) return;
  if(!evs.length){ vbody.innerHTML=stateBox('No timeline','no lifecycle events recorded yet',''); return; }
  var s='<div class="tl">';
  // Each ac_status_append line is '<state>: <text>' - split the STEP out as a
  // colored chip so the lifecycle reads as steps, not prose (board-detail-ux).
  var TL_CLS={working:'acc',spawned:'acc',resumed:'acc',done:'ok',merged:'ok',resolved:'ok',landed:'ok',
    blocked:'warn','needs-decision':'warn',failed:'err',abandoned:'stale',paused:'stale',routed:'acc'};
  for(var i=0;i<evs.length;i++){
    var e=evs[i], ms=Date.parse(e.ts), dur=(i>0)?fmtDur(e.deltaMs):'';
    // Strip any leading marker glyphs (\u23fa, \u23bf, ...) but ONLY when a verb:
    // follows - never eat the first word of a plain-prose event.
    var line=String(e.line||'').replace(/^[^a-zA-Z]+(?=[a-z][a-z-]*:)/,'');
    var vm=/^([a-z][a-z-]*):\s*(.*)$/.exec(line);
    var chip=vm?'<span class="rev '+(TL_CLS[vm[1]]||'')+'">'+esc(vm[1])+'</span> ':'';
    var body=vm?vm[2]:line;
    s+='<div class="tlrow"><div class="tldot'+(vm&&TL_CLS[vm[1]]==='err'?' err':(vm&&TL_CLS[vm[1]]==='warn'?' warn':''))+'"></div>'
      +'<div class="tlmain"><div class="tlline">'+chip+esc(body||'(no text)')+'</div>'
      +'<div class="tlmeta"><span class="tlclock">'+esc(isNaN(ms)?e.ts:clockOf(ms))+'</span>'
      +(dur?'<span class="tldelta">+'+esc(dur)+' after prev step</span>':'')+'</div></div></div>';
  }
  s+='</div>';
  vbody.innerHTML=s;
}
function boardOpenArt(node){
  var path=node.getAttribute('data-art-path'), kind=node.getAttribute('data-art-kind'), title=node.getAttribute('data-art-title');
  var box=document.querySelector('.bdetail'); if(!box) return;   // the detail lives in #page now, not under a modal id
  var prev=box.querySelector('.art.on'); if(prev) prev.classList.remove('on');
  node.classList.add('on');
  var vpath=el('board-vpath'), vkind=el('board-vkind'), vbody=el('board-vbody');
  if(vpath) vpath.textContent=title||'';
  var ob3=el('board-ovbtn'); if(ob3) ob3.hidden=false;
  if(vkind){ vkind.hidden=false; vkind.className='vkind'+(kind==='md'?' md':''); vkind.textContent=(kind==='html'?'HTML':(kind==='md'?'MD':(kind||'file'))); }
  boardSetReviewBtn(path);
  if(vbody) vbody.innerHTML=skeleton();
  var hp=S.route.home?S.route.home.path:'', reqId=(++boardArtReq);
  fetch('/api/artifact?path='+enc(hp)+'&file='+enc(path)).then(function(r){ return r.json(); }).then(function(j){
    if(reqId!==boardArtReq) return;                     // a newer selection (or a close) won
    boardApplyArt(j, kind);
  }).catch(function(){ if(reqId===boardArtReq){ var vb=el('board-vbody'); if(vb) vb.innerHTML=stateBox('Preview unavailable','failed to load','err'); } });
}
function boardApplyArt(j, kind){
  var vb=el('board-vbody'); if(!vb) return;
  if(j && j.error){ vb.innerHTML=stateBox('Preview unavailable', j.error, 'err'); return; }
  if(j.kind==='html'){ vb.innerHTML='<iframe class="vframe" id="board-vframe" title="artifact"></iframe>'; var f=el('board-vframe'); if(f){ f.setAttribute('sandbox',''); f.srcdoc=j.content||''; } return; }
  if(j.kind==='image'){ vb.innerHTML='<img class="vimg" src="'+esc(j.src||'')+'" alt="artifact">'; return; }
  if(j.kind==='text'){ vb.innerHTML='<pre class="vtext">'+esc(j.text||'')+'</pre>'; return; }
  if(j.kind==='bin'){ vb.innerHTML='<div class="vmd"><div class="state"><div class="st-title">Binary file</div><div>'+esc(j.note||'Cannot preview this file.')+'</div></div></div>'; return; }
  // md (default): renderMarkdown already produced XSS-safe html server-side.
  vb.innerHTML='<div class="vmd reader">'+(j.html||'')+'</div>';
}

// ---- Reports / Records (master-detail) ----
// The badge shows the file's extension (json, patch, log, png, ...) - with no
// allowlist a single "md"/"html" kind would label every gate.json "text".
function extBadge(name){ var b=String(name||'').split('/').pop(); var i=b.lastIndexOf('.'); return i>0 ? b.slice(i+1).toLowerCase() : 'file'; }
function pageWhiteboards(){
  var r=S.route, scenes=(S.page&&S.page.scenes)||[];
  var wbHome=enc(r.home?r.home.path:'');
  var s='<div class="wbtools">';
  s+='<input data-wb-new type="text" placeholder="new-scene-name" pattern="[a-z0-9][a-z0-9-]*" aria-label="New whiteboard scene name">';
  s+='<button class="chip" data-wb-open>Create</button>';
  s+='<span class="muted">scenes save to whiteboards/ - agents read them as design input</span>';
  s+='</div>';
  if(!scenes.length) s+='<div class="muted" style="padding:12px">no whiteboards yet - name one and Create</div>';
  var ui=uiFor(routeKey(r));
  for(var i=0;i<scenes.length;i++){
    var sc=scenes[i], nm=(typeof sc==='string')?sc:sc.name, mt=(sc&&sc.mtime)||0;
    s+='<div class="wbrow">';
    if(ui.wbRenaming===nm){
      s+='<input data-wb-rename-input type="text" value="'+esc(ui.wbRenameDraft||nm)+'" pattern="[a-z0-9][a-z0-9-]*" aria-label="New name for '+esc(nm)+'" style="width:200px">';
      s+='<span class="ts"></span>';
      s+='<button class="chip" data-wb-rename-do="'+esc(nm)+'">Save</button>';
      s+='<button class="chip" data-wb-rename-cancel>Cancel</button>';
    } else {
      s+='<span class="fico m" style="background:#ff7043;color:#fff" aria-hidden="true">\u25a6</span><span class="nm">'+esc(nm)+'</span><span class="ts">'+(mt?esc(agoMs(mt)):'')+'</span>';
      var wbUrl='/whiteboard?path='+wbHome+'&scene='+enc(nm);
    s+='<button class="chip" data-tool-open="'+esc(wbUrl)+'" data-tool-title="whiteboard &middot; '+esc(nm)+'">Edit</button>';
    s+='<a class="chip" href="'+esc(wbUrl)+'" target="_blank" rel="noopener" title="open in new tab">&#8599;</a>';
      s+='<button class="chip" data-wb-rename="'+esc(nm)+'">Rename</button>';
      s+='<button class="chip danger" data-wb-del="'+esc(nm)+'">Delete</button>';
    }
    s+='</div>';
  }
  return s;
}

// Cross-home Reviews is a client-only view pref (dash-review-polish-xhome),
// same shape as boardHideDone: persisted, and toggling it changes which
// endpoint routeEndpoint fetches, so a fresh route poll is forced. Reuses the
// SAME invalidation applyRoute uses on a route/fleet change (:5945) - bump
// pollGen and abort pageCtrl - so an in-flight per-fleet fetch can never
// resolve and render under the new flag (a stale response's gen check would
// otherwise still match).
// Active-only view filter (captain 2026-08-18: per-fleet only, no all-homes
// toggle in the UI - /api/reviews?all=1 stays for shims). Pure client filter.
function reviewsActiveOnly(){ try{ return localStorage.getItem('ac_dash_reviews_active')==='1'; }catch(e){ return false; } }
function toggleReviewsActive(){
  var v=!reviewsActiveOnly(); try{ localStorage.setItem('ac_dash_reviews_active', v?'1':'0'); }catch(e){}
  renderPage();
}
// End / reopen a session straight from the list row - same endpoint the
// /review page's own button uses (reviewMutate owns the semantics).
function reviewRowEnd(home, file, reopen){
  if(!home||!file) return;
  var qs='/api/review/end?path='+enc(home)+'&file='+enc(file)+(reopen?'&reopen=1&force=1':'&by=human');
  fetch(qs,{method:'POST'}).then(function(){ S.page=null; renderPage(); pollRoute(); }).catch(function(){});
}
// Revoke a share from the Reviews list - the "turned it on and forgot" path:
// the row shows SHARED, this kills the token, the row re-renders clean.
function stopShare(home, file){
  if(!home||!file) return;
  fetch('/api/review/share?path='+enc(home)+'&file='+enc(file)+'&stop=1',{method:'POST'})
    .then(function(){ S.page=null; renderPage(); pollRoute(); })
    .catch(function(){});
}
function pageReviews(){
  var r=S.route;
  if(!S.page){ return S.pageFail?stateBox('Reviews unavailable','Could not load the review sessions. Retrying.','err'):skeleton(); }
  var all=S.page.reviews||[];
  var act=reviewsActiveOnly();
  var rows=act?all.filter(function(v){ return v.state==='open'; }):all;
  var s='<div class="wbtools"><span class="muted">every review session of this fleet - the session file lives beside its artifact</span>'
    +'<button class="btoggle" type="button" data-reviews-active aria-pressed="'+(act?'true':'false')+'"><span class="sw" aria-hidden="true"></span>Active only</button></div>';
  if(!rows.length) s+='<div class="muted" style="padding:12px">'+(act&&all.length?'no ACTIVE review session - '+all.length+' ended hidden by the filter':'no review sessions yet - open one from a Reports artifact')+'</div>';
  for(var i=0;i<rows.length;i++){
    var v=rows[i];
    var open=v.state==='open';
    var rowHome=r.home?r.home.path:'';
    s+='<div class="wbrow">';
    s+='<span class="rvdot'+(open?' ok':'')+'" aria-hidden="true"></span>';
    s+='<span class="nm">'+esc(v.id)+'</span>';
    s+='<span class="muted">'+(open?(v.listening?'agent listening':'open &middot; idle'):'ended ('+esc(v.endedBy||'?')+')')+'</span>';
    if(v.shared) s+='<span class="chipm shared" title="a guest token link is live for this session">SHARED</span>';
    s+='<span class="muted">'+v.pins+' pin'+(v.pins===1?'':'s')+' &middot; '+v.messages+' msg'+(v.messages===1?'':'s')+'</span>';
    s+='<span class="ts">'+(v.mtime?esc(agoMs(v.mtime)):'')+'</span>';
    var rvUrl='/review?path='+enc(rowHome)+'&file='+enc(v.path);
    s+='<button class="chip" data-tool-open="'+esc(rvUrl)+'" data-tool-title="review &middot; '+esc(v.id.split('/').pop())+'">Open</button>';
    s+='<a class="chip" href="'+esc(rvUrl)+'" target="_blank" rel="noopener" title="open in new tab">&#8599;</a>';
    if(open) s+='<button class="chip" data-review-end="'+esc(rowHome)+'" data-review-end-file="'+esc(v.path)+'" title="end this review session (reopen stays possible)">End session</button>';
    else s+='<button class="chip" data-review-reopen="'+esc(rowHome)+'" data-review-reopen-file="'+esc(v.path)+'" title="reopen this ended session - wakes the fleet">Reopen</button>';
    if(v.shared) s+='<button class="chip" data-stop-share="'+esc(rowHome)+'" data-stop-share-file="'+esc(v.path)+'" title="revoke the guest link">Stop share</button>';
    s+='</div>';
  }
  return s;
}

function pageReports(){
  var r=S.route, ui=uiFor(routeKey(r));
  if(!S.page){ return S.pageFail?stateBox('Reports unavailable','Could not load the artifact list. Retrying.','err'):skeleton(); }
  var arts=S.page.artifacts||[];
  // Empty-viewer landing was a dead screen (all-menu review): with no
  // selection, open the NEWEST artifact - replace, so back leaves the page.
  if(!r.sel && arts.length){
    // Prefer the newest READABLE artifact (md/html) - the raw newest is often
    // review-loop machinery (*.session.json) or a screenshot.
    var best=null;
    for(var bi=0;bi<arts.length;bi++){ var ab=arts[bi];
      if((ab.kind==='md'||ab.kind==='html') && !/\.session\.json$/.test(ab.id) && (!best||ab.mtime>best.mtime)) best=ab; }
    if(!best){ best=arts[0]; for(var bj=1;bj<arts.length;bj++) if(arts[bj].mtime>best.mtime) best=arts[bj]; }
    setTimeout(function(){ var cr=S.route; if(cr&&cr.name==='reports'&&!cr.sel&&cr.fleet===r.fleet) navigate('/fleets/'+enc(cr.fleet)+'/reports/'+enc(best.id),{replace:true}); },0);
  }
  var q=ui.query.toLowerCase(), flt=ui.filter;
  var shown=arts.filter(function(a){
    if(flt==='md' && a.kind!=='md') return false;
    if(flt==='html' && a.kind!=='html') return false;
    if(q){ return (a.family+' '+a.stage+' '+a.id).toLowerCase().indexOf(q)>=0; }
    return true;
  });
  var tree=(reportsView()==='tree');
  var list='';
  list+='<div class="ltools">';
  list+='<input class="search-in" type="search" data-list-search placeholder="Search artifacts…" aria-label="Search artifacts" autocomplete="off" spellcheck="false">';
  list+='<div class="filters">'+chip('all','All',flt)+chip('md','Markdown',flt)+chip('html','HTML',flt)
       +'<span class="vsw" role="group" aria-label="Artifact list layout">'
       +'<button class="chip" data-rview="tree" aria-pressed="'+(tree?'true':'false')+'">Tree</button>'
       +'<button class="chip" data-rview="flat" aria-pressed="'+(tree?'false':'true')+'">Flat</button>'
       +'</span></div>';
  list+='</div><div class="lbody">';
  var total=(S.page&&S.page.total)||arts.length;
  if(total>arts.length){
    list+='<div class="muted" style="padding:6px 12px">first '+((S.page&&S.page.folders)||0)+' of '+((S.page&&S.page.totalFolders)||0)+' folders ('+arts.length+'/'+total+' files) <button class="chip" data-reports-all>Show all</button></div>';
  }
  if(!shown.length) list+='<div class="muted" style="padding:12px">'+(arts.length?'no matching artifacts':'no artifacts')+'</div>';
  // Tree: family -> each sub-dir -> files. A narrowed list (query or a kind chip)
  // renders every node expanded by default - a tree that hides a search hit reads
  // as broken.
  else if(tree) list+=artTree(groupArtifacts(shown), r, ui, !!q||flt!=='all', 0);
  else {
  // Flat, time-sorted (newest first); family is shown per row so it stays identifiable.
  for(var i=0;i<shown.length;i++){ var a=shown[i];
    var cur=(r.sel===a.id)?' aria-current="true"':'';
    list+='<a class="arow arow2" href="/fleets/'+enc(r.fleet)+'/reports/'+enc(a.id)+'" data-link'+cur+'>';
    // Two lines: the stage owns a full-width line of its own, because it is what
    // tells two rows of one family apart and the ellipsis cuts from the right -
    // sharing one line with family+badge+ts clipped exactly that discriminator.
    list+='<span class="astage" title="'+esc(a.family)+' / '+esc(a.stage)+'">'+fileIco(a.id)+' '+esc(a.stage)+'</span>';
    list+='<span class="ameta"><span class="afam">'+esc(a.family)+'</span><span class="badge">'+esc(extBadge(a.id))+'</span><span class="ts">'+esc(agoMs(a.mtime))+'</span></span></a>';
  }
  }
  list+='</div>';
  return '<div class="md-layout"><div class="md-list" data-listscroll>'+list+'</div>'+viewerHtml()+'</div>';
}
function reportsView(){ try{ return localStorage.getItem('ac_dash_rview')==='flat'?'flat':'tree'; }catch(e){ return 'tree'; } }
/* Collapsed by default, EXCEPT the ancestor chain of the selected artifact (so a
   deep link still reveals its selection) and the single newest family node (so
   the page is never a wall of closed rows on first paint). */
function treeDefOpen(d, r, i, depth){
  if(depth===0 && i===0) return true;
  var sel=r.sel;
  return !!sel && (sel===d.key || sel.indexOf(d.key+'/')===0);
}
// Material-icon-theme style tree icons (captain 2026-08-18), self-contained:
// files render as the theme's flat colored rounded-square glyph (no icon
// font, no network - a CSS chip carries color + white glyph), folders as the
// theme's filled blue-grey folder SVG with a lighter open flap.
function fileIco(name){
  var ext=(String(name).split('.').pop()||'').toLowerCase();
  if(/^(png|jpe?g|gif|webp)$/.test(ext)) ext='img';
  var M={
    md:['#42a5f5','M'], html:['#e65100','&lt;&gt;'], htm:['#e65100','&lt;&gt;'],
    json:['#f9a825','{}'], yaml:['#ef5350','Y'], yml:['#ef5350','Y'],
    log:['#90a4ae','\u2261'], txt:['#90a4ae','\u2261'],
    img:['#26a69a','\u25eb'], svg:['#ffb300','\u25eb'],
    py:['#3776ab','Py'], sh:['#455a64','$'], ts:['#0288d1','TS'],
    js:['#f7df1e','JS'], csv:['#66bb6a','\u229e']
  };
  var m=M[ext]||['#78909c','\u00b7'];
  var ink=(ext==='js')?'#3b3b3b':'#fff';
  return '<span class="fico m" style="background:'+m[0]+';color:'+ink+'" aria-hidden="true">'+m[1]+'</span>';
}
function folderIco(open){
  return '<span class="fico dir" aria-hidden="true"><svg viewBox="0 0 16 16">'
    +'<path fill="#90a4ae" d="M1.3 3.6c0-.5.4-.9.9-.9h3.6l1.5 1.6h6.5c.5 0 .9.4.9.9v7c0 .5-.4.9-.9.9H2.2c-.5 0-.9-.4-.9-.9z"/>'
    +(open?'<path fill="#b0bec5" d="M2.6 6.8h12l-1.4 6.3H2.9c-.4 0-.7-.3-.7-.7z"/>':'')
    +'</svg></span>';
}
function artTree(n, r, ui, force, depth){
  var s='', pad=8+depth*11;
  for(var i=0;i<n.dirs.length;i++){ var d=n.dirs[i], k='tree:'+d.key;
    var open=(k in ui.exp)?ui.exp[k]:(force||treeDefOpen(d, r, i, depth));
    // A depth-0 folder IS a family dir name (data/<family>/), already the id the
    // board route takes - so it links straight at the detail, un-normalized: the
    // Processes row normalizes because its input is a TASK id, this one must not.
    // EXCEPT "lavish": collectArtifacts nests the pooled worktrees' review pages
    // under a synthetic top-level node (:1075), a bucket rather than a family.
    var fam=(depth===0 && d.name!=='lavish')
      ? '<a class="tlink" href="/fleets/'+enc(r.fleet)+'/board/'+enc(d.name)+'" data-link title="Open task '+esc(d.name)+'">&#8599;</a>' : '';
    s+=(fam?'<div class="tnoderow">':'');
    s+='<button class="tnode" data-tree="'+esc(d.key)+'" aria-expanded="'+(open?'true':'false')+'" style="padding-left:'+pad+'px" title="'+esc(d.name)+'">';
    s+='<span class="caret">'+(open?'&#9662;':'&#9656;')+'</span>'+folderIco(open)+'<span class="tname">'+esc(d.name)+'</span><span class="cnt">'+d.count+'</span></button>';
    s+=fam+(fam?'</div>':'');
    if(open) s+=artTree(d, r, ui, force, depth+1);
  }
  for(var j=0;j<n.files.length;j++){ var f=n.files[j], a=f.art;
    var cur=(r.sel===a.id)?' aria-current="true"':'';
    // The leaf is the file's OWN basename: inside the tree the dirs ARE the
    // ancestors, so repeating them is noise. It WRAPS instead of ellipsising -
    // a clipped tail is exactly what cost this page a round before.
    s+='<a class="arow atree" href="/fleets/'+enc(r.fleet)+'/reports/'+enc(a.id)+'" data-link'+cur+' style="padding-left:'+(pad+14)+'px" title="'+esc(a.id)+'">';
    s+=fileIco(f.name)+'<span class="aname">'+esc(f.name)+'</span><span class="ts">'+esc(agoMs(a.mtime))+'</span></a>';
  }
  return s;
}
function pageRecords(){
  var r=S.route, ui=uiFor(routeKey(r));
  if(!S.page){ return S.pageFail?stateBox('Records unavailable','Could not load the ledger list. Retrying.','err'):skeleton(); }
  var recs=S.page.records||[];
  if(!r.sel && recs.length){
    var dflt='backlog.md'; var has=false;
    for(var di=0;di<recs.length;di++) if(recs[di].name===dflt){ has=true; break; }
    var pick=has?dflt:recs[0].name;
    setTimeout(function(){ var cr=S.route; if(cr&&cr.name==='records'&&!cr.sel&&cr.fleet===r.fleet) navigate('/fleets/'+enc(cr.fleet)+'/records/'+enc(pick),{replace:true}); },0);
  }
  var q=ui.query.toLowerCase();
  var shown=recs.filter(function(x){ return !q || x.name.toLowerCase().indexOf(q)>=0; });
  var list='<div class="ltools"><input class="search-in" type="search" data-list-search placeholder="Search ledgers…" aria-label="Search ledgers" autocomplete="off" spellcheck="false"></div><div class="lbody">';
  if(!shown.length) list+='<div class="muted" style="padding:12px">no ledgers</div>';
  for(var i=0;i<shown.length;i++){ var x=shown[i]; var cur=(r.sel===x.name)?' aria-current="true"':'';
    list+='<a class="arow" href="/fleets/'+enc(r.fleet)+'/records/'+enc(x.name)+'" data-link'+cur+'>';
    list+=fileIco(x.name)+'<span class="aname">'+esc(x.name)+'</span><span class="ts">'+esc(agoMs(x.mtime))+'</span></a>';
  }
  list+='</div>';
  return '<div class="md-layout"><div class="md-list" data-listscroll>'+list+'</div>'+viewerHtml()+'</div>';
}

// ---- Domains (dash-domain-records: crewdomain registry + package panels) ----
function domainMemberBadge(present){ return present?'<span class="badge ok">present</span>':'<span class="badge warn">missing</span>'; }
function pageDomains(){
  if(!S.page){ return S.pageFail?stateBox('Domains unavailable','Could not load the crewdomain registry. Retrying.','err'):skeleton(); }
  var domains=S.page.domains||[];
  if(!domains.length) return stateBox('No crewdomains registered', 'records/crewdomains.md has no entries yet - create one with bin/ac-domain.sh new.', '');
  var s='<div class="tblwrap"><table class="tbl"><thead><tr><th>ID</th><th>Charter</th><th>Scope</th><th>Added</th></tr></thead><tbody>';
  for(var i=0;i<domains.length;i++){ var d=domains[i];
    if(d.cls==='INVALID'){
      s+='<tr><td colspan="4"><span class="badge err">INVALID</span> <span class="mono">'+esc(d.id)+'</span> &mdash; '+esc(d.reason)+'</td></tr>';
    } else {
      s+='<tr><td class="id">'+esc(d.id)+'</td><td>'+esc(d.charter)+'</td><td>'+esc(d.scope||'(unset)')+'</td><td class="mono">'+esc(d.added)+'</td></tr>';
    }
  }
  s+='</tbody></table></div>';
  for(var j=0;j<domains.length;j++){ if(domains[j].cls==='VALID') s+=domainPanel(domains[j]); }
  return s;
}
function domainPanel(d){
  var s='<details class="card" style="margin-bottom:9px;padding:11px 13px">';
  s+='<summary style="cursor:pointer"><span class="mono" style="color:var(--accent)">'+esc(d.id)+'</span>';
  if(d.backlog) s+=' <span class="muted" style="font-size:12px">queued '+d.backlog.queued+' &middot; in flight '+d.backlog.inFlight+' &middot; done '+d.backlog.done+'</span>';
  s+='</summary>';
  s+='<div class="tblwrap" style="margin-top:10px"><table class="tbl"><tbody>';
  s+='<tr><th>records/backlog.md</th><td>'+domainMemberBadge(d.members.backlog)+'</td><th>records/projects.md</th><td>'+domainMemberBadge(d.members.projectsDoc)+'</td></tr>';
  s+='<tr><th>CREWMATE.md</th><td>'+domainMemberBadge(d.members.crewmate)+'</td><th>projects/ links</th><td>'+d.projects.length+'</td></tr>';
  s+='</tbody></table></div>';
  if(d.projects.length){
    s+='<div class="tblwrap" style="margin-top:10px"><table class="tbl"><thead><tr><th>Entry</th><th>Resolved target</th><th>State</th></tr></thead><tbody>';
    for(var k=0;k<d.projects.length;k++){ var p=d.projects[k];
      s+='<tr><td class="mono">'+esc(p.name)+'</td><td class="mono">'+esc(p.target||'—')+'</td><td>'+(p.dangling?'<span class="badge err">dangling</span>':'<span class="badge ok">ok</span>')+'</td></tr>';
    }
    s+='</tbody></table></div>';
  }
  if(d.projectsHtml) s+='<div style="margin-top:12px"><h3 style="font-size:13px">records/projects.md</h3><div class="reader">'+d.projectsHtml+'</div></div>';
  if(d.crewmateHtml) s+='<div style="margin-top:12px"><h3 style="font-size:13px">CREWMATE.md</h3><div class="reader">'+d.crewmateHtml+'</div></div>';
  s+='</details>';
  return s;
}

function viewerHtml(){
  var v=S.viewer;
  if(!v){ return '<div class="viewer"><div class="vbody"><div class="state"><div class="st-title">No file selected</div><div>Choose an item on the left to open the reader.</div></div></div></div>'; }
  var s='<div class="viewer"><div class="vhead"><span class="vtitle">'+esc(v.title||v.sel)+'</span>';
  if(v.stale) s+='<span class="badge stale">changed on disk</span>';
  else if(!v.loading && !v.error) s+='<span class="badge ok">fresh</span>';
  if(v.mtime) s+='<span class="ts">modified '+esc(fmtTime(v.mtime))+'</span>';
  s+='<span class="vsp">';
  if(v.stale) s+='<button class="btn sm" data-reload>Reload</button>';
  // Review opens the native /review loop; v.path is set at SELECTION time,
  // so the gate holds during v.loading too and never flickers a button in.
  if(v.name==='reports' && reviewableArtifact(v.path)){ var rvUrl='/review?path='+enc(v.homePath)+'&file='+enc(v.path); s+='<button class="btn sm" data-tool-open="'+esc(rvUrl)+'" data-tool-title="review &middot; '+esc(v.path.split('/').pop())+'">Review &#9655;</button>'; s+='<a class="btn sm" href="'+esc(rvUrl)+'" target="_blank" rel="noopener" title="open in new tab">&#8599;</a>'; }
  if(v.name==='reports' && v.path) s+='<button class="btn sm" data-reveal="'+esc(v.homePath)+'" data-reveal-file="'+esc(v.path)+'" title="reveal this file in Finder">Reveal in Finder</button>';
  s+='</span></div>';
  // A loaded body is a PRESERVED island (data-preserve): morph never re-diffs it
  // on poll, so iframe document identity, reader scroll, text selection and focus
  // survive. The key carries v.gen so a new selection or an explicit Reload (which
  // bumps gen) remounts fresh content. Loading/error bodies are NOT preserved, so
  // the skeleton->content transition renders normally.
  var pk=esc(v.key+'#'+(v.gen||0));
  if(v.loading){ s+='<div class="vbody">'+skeleton()+'</div>'; }
  else if(v.error){ s+='<div class="vbody"><div class="state err"><div class="st-title">Preview unavailable</div><div>'+esc(v.error)+'</div></div></div>'; }
  else if(v.kind==='html'){ s+='<div class="vbody frameonly" data-viewerscroll data-preserve="'+pk+'"><iframe class="frame" id="viewer-frame" data-frame="'+esc(v.key)+'" title="'+esc(v.title||'artifact')+'"></iframe></div>'; }
  else if(v.kind==='image'){ s+='<div class="vbody imgview" data-viewerscroll data-preserve="'+pk+'"><img class="viewimg" src="'+esc(v.src||'')+'" alt="'+esc(v.title||'image')+'"></div>'; }
  else if(v.kind==='text'){ s+='<div class="vbody" data-viewerscroll data-preserve="'+pk+'">'+(v.truncated?'<div class="muted" style="margin-bottom:8px">Showing the first 1 MB &mdash; file truncated.</div>':'')+'<pre class="filetext">'+esc(v.text||'')+'</pre></div>'; }
  else if(v.kind==='bin'){ s+='<div class="vbody" data-viewerscroll data-preserve="'+pk+'"><div class="state"><div class="st-title">Binary file</div><div>'+esc(v.note||'Cannot preview this file.')+'</div></div></div>'; }
  else { s+='<div class="vbody" data-viewerscroll data-preserve="'+pk+'"><div class="reader">'+(v.body||'')+'</div></div>'; }
  s+='</div>';
  return s;
}

// ---- Learning (fleet-local, read-only) ----
function learningBadge(state){
  var cls='badge';
  if(state==='active'||state==='complete'||state==='continue') cls+=' ok';
  else if(state==='stale'||state==='pending'||state==='migration-pending'||state==='ask-captain'||state==='applying') cls+=' warn';
  else if(state==='shadowed'||state==='revise') cls+=' err';
  return '<span class="'+cls+'">'+esc(state||'unknown')+'</span>';
}
function learningWhen(value){
  if(!value) return '—';
  var n=Date.parse(value);
  return isNaN(n)?esc(value):esc(fmtTime(n));
}
function learningDecisionRow(d, withBody){
  var s='<div class="card" style="margin-bottom:9px;padding:11px 13px">';
  s+='<div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap"><span class="mono" style="color:var(--accent)">'+esc(d.subject)+'</span>'+learningBadge(d.decision)+learningBadge(d.apply_state)+'</div>';
  s+='<div class="muted" style="font-size:12px;margin-top:5px">'+esc(d.mode||'—')+' &middot; '+esc(d.authority||'—')+' &middot; '+esc(d.engine||'—')+(d.model?' / '+esc(d.model):'')+' &middot; '+learningWhen(d.reviewed_at)+'</div>';
  if(d.grounds) s+='<div style="margin-top:7px">'+esc(d.grounds)+'</div>';
  if(withBody) s+='<details style="margin-top:9px"><summary class="more">Decision receipt</summary><div class="reader" style="margin-top:8px">'+(d.html||'')+'</div></details>';
  s+='</div>';
  return s;
}
var brainQ={}, brainRes=null, brainBusy=false, brainTimer=null, brainAns=null, brainAskBusy=false;
function brainAsk(){
  var hp=(S.route&&S.route.home&&S.route.home.path)||''; var q=brainQ[hp]||'';
  if(!q||brainAskBusy) return; brainAskBusy=true; brainAns=null; renderPage();
  fetch('/api/brain-synthesize?path='+enc(hp)+'&q='+enc(q)).then(function(r){ return r.json(); }).then(function(j){
    brainAns=j; brainAskBusy=false; if(S.route&&S.route.name==='brain') renderPage();
  }).catch(function(){ brainAskBusy=false; renderPage(); });
}
function brainSearch(){
  var hp=(S.route&&S.route.home&&S.route.home.path)||''; var q=brainQ[hp]||'';
  if(brainBusy) return; brainBusy=true;
  fetch('/api/brain-recall?path='+enc(hp)+'&q='+enc(q)).then(function(r){ return r.json(); }).then(function(j){
    brainRes=j; brainBusy=false; if(S.route&&S.route.name==='brain') renderPage();
  }).catch(function(){ brainBusy=false; });
}
function pageBrain(){
  var st=S.page;
  if(!st){ return S.pageFail?stateBox('Brain unavailable','Could not read this home\u2019s brain.','err'):skeleton(); }
  if(!st.present){
    return stateBox('No brain yet','This home has no state/brain.sqlite. Build it with: bin/ac-brain.sh sync --home <home>','');
  }
  var hp=(S.route&&S.route.home&&S.route.home.path)||'';
  var s='<div class="kpis">'
    +'<div class="kpi"><b>'+esc(String(st.pages))+'</b><span>pages</span></div>'
    +'<div class="kpi"><b>'+esc(String(st.facts))+'</b><span>active facts</span></div>'
    +'<div class="kpi"><b>'+esc(st.last_sync?String(st.last_sync).slice(0,16).replace('T',' '):'never')+'</b><span>last sync</span></div>'
    +'</div>'
    +'<div class="cfg-note">Semantic search / synthesize keys: <a href="/fleets/'+enc(S.route.fleet)+'/config" data-link>Config \u2192 Brain LLM providers</a></div>';
  s+='<div style="margin:10px 0"><input class="search-in" type="search" data-brain-q placeholder="Ask the brain\u2026" aria-label="Ask the brain" autocomplete="off" spellcheck="false" value="'+esc(brainQ[hp]||'')+'" style="width:60%;max-width:520px"> '
    +'<button class="btn sm primary" data-brain-go title="Hybrid search - instant, free">Recall</button> '
    +'<button class="btn sm" data-brain-ask title="LLM-composed answer with citations - costs tokens, takes seconds">Ask (LLM)</button>'
    +(brainBusy?' <span class="badge">searching\u2026</span>':'')
    +(brainAskBusy?' <span class="badge warn">composing\u2026</span>':'')+'</div>';
  if(brainAns){
    s+='<div class="cfg-field" style="display:block"><div class="fname">Answer <span class="badge">'+esc(brainAns.synthesis_status||'')+'</span></div>'
      +'<div style="white-space:pre-wrap;margin-top:6px">'+esc(brainAns.answer||'')+'</div>';
    var src=brainAns.sources||[];
    if(src.length){ s+='<div class="fdesc" style="margin-top:6px">sources: ';
      for(var si=0;si<src.length;si++){ s+=(si?', ':'')+'<a href="/review?path='+enc(hp)+'&file='+enc(hp+'/'+(src[si].path||''))+'" target="_blank">'+esc(src[si].slug)+'</a>'; }
      s+='</div>'; }
    s+='</div>';
  }
  var res=brainRes;
  if(res && res.results && res.results.length){
    if(res.search_degraded) s+='<div class="cfg-note">degraded: '+esc(res.search_degraded)+'</div>';
    for(var i=0;i<res.results.length;i++){ var h=res.results[i];
      var link='/review?path='+enc(hp)+'&file='+enc(hp+'/'+(h.path||''));
      s+='<div class="cfg-field"><div class="fname"><a href="'+esc(link)+'" target="_blank">'+esc(h.title||h.slug)+'</a>'
        +'<div class="fdesc">'+esc(h.slug)+' \u00b7 '+esc(h.evidence||'')+' \u00b7 '+esc(h.trust||'')+'</div></div>'
        +'<div class="cfg-val" style="max-width:52%">'+esc((h.snippet||'').slice(0,240))+'</div></div>';
    }
  } else if(res && res.results){ s+='<div class="cfg-note">No hits.</div>'; }
  var facts=(res&&res.facts&&res.facts.length)?res.facts:null;
  if(!res){ brainSearch(); }
  if(facts){
    s+='<h2 style="font-size:14px;margin:14px 0 6px">Working-memory facts</h2>';
    for(var f=0;f<facts.length;f++){ var fa=facts[f];
      s+='<div class="cfg-field" style="display:block"><div class="fname">['+esc(fa.kind||'fact')+'] '+esc(fa.fact)
        +'<div class="fdesc">'+esc(fa.provenance||'')+' \u00b7 '+esc(fa.agent||'')+' \u00b7 '+esc((fa.created_at||'').slice(0,16).replace('T',' '))+'</div></div></div>';
    }
  }
  return s;
}
function pageLearning(){
  var r=S.route, ui=uiFor(routeKey(r));
  if(!S.page){ return S.pageFail?stateBox('Learning unavailable','Could not load the fleet learning surface. Retrying.','err'):skeleton(); }
  var view=ui.sec.learning||'skills';
  var tabs=[['skills','Skills'],['pending','Pending'],['archive','Archive'],['decisions','Decisions']];
  var s='<div class="filters" role="tablist" aria-label="Learning views" style="margin-bottom:14px">';
  for(var t=0;t<tabs.length;t++) s+='<button class="chip" data-learning-view="'+tabs[t][0]+'" aria-pressed="'+(view===tabs[t][0]?'true':'false')+'">'+tabs[t][1]+'</button>';
  s+='</div>';
  if(view==='skills') return s+learningSkills(ui);
  if(view==='pending') return s+learningPending();
  if(view==='archive') return s+learningArchive();
  return s+learningDecisions();
}
function learningSkills(ui){
  var skills=S.page.skills||[], q=ui.query.toLowerCase(), flt=ui.filter||'all';
  var shown=skills.filter(function(skill){
    if(flt!=='all' && skill.status!==flt) return false;
    return !q || (skill.name+' '+skill.description).toLowerCase().indexOf(q)>=0;
  });
  var s='<div class="filters" style="margin-bottom:14px"><input class="search-in" type="search" data-list-search placeholder="Search fleet skills…" aria-label="Search fleet skills" autocomplete="off" spellcheck="false">';
  s+=chip('all','All',flt)+chip('active','Active',flt)+chip('stale','Stale',flt)+chip('shadowed','Shadowed',flt)+'</div>';
  if(!shown.length) return s+'<div class="state"><div class="st-title">No matching fleet skills</div><div>The selected fleet has no skill matching this search and state filter.</div></div>';
  for(var i=0;i<shown.length;i++){ var skill=shown[i], d=skill.latest_decision;
    s+='<details class="card" style="margin-bottom:9px;padding:11px 13px">';
    s+='<summary style="cursor:pointer"><span class="mono" style="color:var(--accent)">'+esc(skill.name)+'</span> '+learningBadge(skill.status);
    if(d) s+=' <span class="muted" style="font-size:12px">latest gate '+esc(d.decision)+'</span>';
    s+='<div style="margin-top:5px">'+esc(skill.description||'No description.')+'</div></summary>';
    s+='<div class="tblwrap" style="margin-top:10px"><table class="tbl"><tbody>';
    s+='<tr><th>Landed</th><td>'+learningWhen(skill.landed)+'</td><th>Updated</th><td>'+learningWhen(skill.updated)+'</td></tr>';
    s+='<tr><th>Sources</th><td>'+skill.sources+'</td><th>Seeded</th><td>'+skill.seeded_count+(skill.last_seeded?' &middot; '+learningWhen(skill.last_seeded):'')+'</td></tr>';
    s+='</tbody></table></div>';
    s+='<div id="learning-skill-'+esc(skill.name)+'" style="margin-top:12px"><h3 style="font-size:13px">SKILL.md</h3><div class="reader">'+(skill.skill_html||'')+'</div></div>';
    if(skill.evidence_html) s+='<div id="learning-evidence-'+esc(skill.name)+'" style="margin-top:12px"><h3 style="font-size:13px">Learning evidence</h3><div class="reader">'+skill.evidence_html+'</div></div>';
    if(d) s+='<div id="learning-decision-'+esc(skill.name)+'" style="margin-top:12px"><h3 style="font-size:13px">Latest decision receipt</h3>'+learningDecisionRow(d,true)+'</div>';
    s+='</details>';
  }
  return s;
}
function learningPending(){
  var p=S.page.pending||{raw_count:0,active_run:null,waiting:[],waiting_gate:[],migration:[],html:''};
  var s='<div class="card" style="margin-bottom:12px;padding:11px 13px"><div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap"><b>Active Learning run</b>';
  s+=p.active_run?'<span class="mono">'+esc(p.active_run)+'</span>':'<span class="muted">none</span>';
  s+='</div></div>';
  if((p.migration||[]).length){ s+='<section class="disc"><div class="dh">MIGRATION PENDING<span class="cnt">'+p.migration.length+'</span></div><div class="dbody">';
    for(var i=0;i<p.migration.length;i++) s+='<div class="blrow"><span class="bid">'+esc(p.migration[i].name)+'</span><span class="btext">'+learningBadge('migration-pending')+' legacy @container pointer from '+esc(p.migration[i].updated||'unknown date')+'</span></div>';
    s+='</div></section>';
  }
  if((p.waiting||[]).length){ s+='<h2 style="font-size:14px;margin:16px 0 8px">Waiting on captain</h2>';
    for(var w=0;w<p.waiting.length;w++) s+=learningDecisionRow(p.waiting[w],true);
  }
  if((p.waiting_gate||[]).length){ s+='<h2 style="font-size:14px;margin:16px 0 8px">Waiting on maintenance decision</h2>';
    for(var g=0;g<p.waiting_gate.length;g++) s+='<div class="blrow"><span class="bid">'+esc(p.waiting_gate[g].subject)+'</span><span class="btext">'+learningBadge(p.waiting_gate[g].state)+'</span></div>';
  }
  s+='<h2 style="font-size:14px;margin:16px 0 8px">Raw unconsumed records '+learningBadge(p.raw_count?'pending':'settled')+'</h2>';
  s+=p.html?'<div class="reader">'+p.html+'</div>':'<div class="state"><div class="st-title">No pending learning records</div><div>Every raw record in the active ledger is settled.</div></div>';
  return s;
}
function learningArchive(){
  var archives=S.page.archives||[];
  if(!archives.length) return '<div class="state"><div class="st-title">No learning archives</div><div>No per-skill, archived-skill, captain, or backlog archive exists for this fleet.</div></div>';
  var s='';
  for(var i=0;i<archives.length;i++){ var a=archives[i];
    s+='<details class="card" style="margin-bottom:9px;padding:11px 13px"><summary style="cursor:pointer"><span class="mono" style="color:var(--accent)">'+esc(a.name)+'</span> '+learningBadge('archived')+' <span class="badge">'+esc(a.kind)+'</span><span class="muted" style="font-size:12px;margin-left:8px">'+esc(fmtTime(a.mtime))+'</span></summary>';
    s+='<div class="reader" style="margin-top:10px">'+(a.html||'')+'</div></details>';
  }
  return s;
}
function learningDecisions(){
  var decisions=S.page.decisions||[];
  if(!decisions.length) return '<div class="state"><div class="st-title">No maintenance decisions</div><div>No Learning or Curate gate receipt exists for this fleet.</div></div>';
  var s='';
  for(var i=0;i<decisions.length;i++) s+=learningDecisionRow(decisions[i],true);
  return s;
}

// ---- Search ----
var searchTimer=null;
function pageSearch(){
  var ui=uiFor('search');
  var s='<div class="searchpage">';
  s+='<input class="search-in" style="width:100%;font-size:15px;padding:10px 14px" type="search" data-search-page placeholder="Search tasks across fleets…" aria-label="Search tasks across fleets" autocomplete="off" spellcheck="false">';
  var q=ui.query.trim();
  if(q.length<2){ s+='<div class="state"><div class="st-title">Search across fleets</div><div>Type at least two characters to search every fleet\\'s backlog.</div></div></div>'; return s; }
  if(S.searchErr){ s+=stateBox('Search failed','The search request failed. It will retry on the next refresh.','err')+'</div>'; return s; }
  var hits=S.searchHits||[];
  s+='<div class="muted" style="margin:12px 0">'+hits.length+' result'+(hits.length===1?'':'s')+' &middot; query retained</div>';
  if(!hits.length){ s+='<div class="state"><div class="st-title">No matches</div><div>No backlog line matches "'+esc(q)+'".</div></div></div>'; return s; }
  for(var i=0;i<hits.length;i++){ var hit=hits[i]; var fn=homeName(hit.home);
    var rk='sr:'+i, openRow=!!ui.exp[rk];
    s+='<div class="sresult"><div class="rhead"><span class="rfleet">'+esc(fn)+'</span>'
      +(hit.family?'<span class="mono" style="color:var(--accent);font-size:12px">'+esc(hit.family)+'</span>':'')
      +'<span class="badge">'+esc(hit.section)+'</span></div>';
    // A raw ledger row runs hundreds of words - clamp it and let the captain
    // expand the one they care about (all-menu review).
    s+='<div class="rline'+(openRow?'':' clip')+'">'+hl(hit.line, q)+'</div>';
    s+='<div class="rlinks"><a href="/fleets/'+enc(fn)+'/board/'+enc(hit.family)+'" data-link>Open task &rarr;</a>';
    s+='<a href="/fleets/'+enc(fn)+'/reports" data-link data-jumpq="'+esc(hit.family)+'">Reports &rarr;</a>';
    s+='<button class="chip" data-disc="'+rk+'">'+(openRow?'less':'more')+'</button></div></div>';
  }
  s+='</div>';
  return s;
}
function hl(text, q){
  if(!q) return esc(text);
  var lo=text.toLowerCase(), lq=q.toLowerCase(), out='', i=0, idx;
  while((idx=lo.indexOf(lq, i))>=0){ out+=esc(text.slice(i,idx))+'<mark>'+esc(text.slice(idx,idx+lq.length))+'</mark>'; i=idx+lq.length; }
  return out+esc(text.slice(i));
}
function runSearch(){
  var ui=uiFor('search'); var q=ui.query.trim();
  if(q.length<2){ S.searchHits=[]; S.searchErr=false; renderPage(); return; }
  fetch('/api/search?q='+enc(q)).then(function(r){ return r.json(); }).then(function(hits){
    if(uiFor('search').query.trim()!==q) return; // stale
    S.searchHits = Array.isArray(hits)?hits:[]; S.searchErr=false;
    if(S.route&&S.route.name==='search') renderPage();
  }).catch(function(){ if(uiFor('search').query.trim()===q){ S.searchErr=true; if(S.route&&S.route.name==='search') renderPage(); } });
}

// ---- Config ----
var CFG_SECTIONS=[
  {id:'runtime', title:'Runtime', keys:['flow','promote','backend']},
  {id:'models', title:'Models', keys:['crew-harness','model','effort','codereview-agent','codereview-model','codereview-effort','qa-agent','qa-model','qa-effort','gate-agent','gate-model','gate-effort']},
  {id:'parallelism', title:'Parallelism', keys:['room-parallel']},
  {id:'learning', title:'Learning', keys:['learn-every','curate-every']},
  {id:'remote', title:'Remote', keys:['remote-mirror','remote-poll-interval','slack-channel','slack-captain-id']},
  {id:'identity', title:'Identity', keys:['captain']}
];
function pageConfig(){
  var r=S.route;
  if(!S.page){ return S.pageFail?stateBox('Config unavailable','Could not load the config knobs. Retrying.','err'):skeleton(); }
  var ed=(S.page.editable)||[], byName={};
  for(var i=0;i<ed.length;i++) byName[ed[i].name]=ed[i];
  var covered={}; for(var g=0;g<CFG_SECTIONS.length;g++){ for(var k=0;k<CFG_SECTIONS[g].keys.length;k++) covered[CFG_SECTIONS[g].keys[k]]=1; }
  var others=[]; for(var e=0;e<ed.length;e++){ if(!covered[ed[e].name]) others.push(ed[e].name); }
  var secs=CFG_SECTIONS.slice(); if(others.length) secs=secs.concat([{id:'other', title:'Other', keys:others}]);
  secs=secs.concat([{id:'dispatch', title:'Crew dispatch', keys:[]},{id:'providers', title:'Brain LLM providers', keys:[]}]);
  var sec=S.cfgSection; var chosen=null;
  for(var si=0;si<secs.length;si++){ if(secs[si].id===sec) chosen=secs[si]; }
  if(!chosen) chosen=secs[0];

  var s='<div class="cfg-layout"><ul class="cfg-secs" role="tablist" aria-label="Config sections">';
  for(var t=0;t<secs.length;t++){ var on=secs[t].id===chosen.id;
    s+='<li><button data-cfg-section="'+esc(secs[t].id)+'"'+(on?' aria-current="true"':'')+'>'+esc(secs[t].title)+'</button></li>';
  }
  s+='</ul><div class="cfg-panel">';
  s+='<h2 style="font-size:15px;margin-bottom:6px">'+esc(chosen.title)+'</h2>';
  s+='<div class="cfg-note">Changes apply on the next fleet session. Writes are confirmation-gated and receipted.</div>';
  if(S.cfgMsg){ s+='<div class="'+(S.cfgMsg.ok?'badge ok':'badge err')+'" style="margin-bottom:10px">'+esc(S.cfgMsg.text)+'</div>'; }
  if(chosen.id==='dispatch'){ s+=dispatchPanel(); }
  else if(chosen.id==='providers'){ s+=providersPanel(); }
  else {
  for(var f=0;f<chosen.keys.length;f++){ var name=chosen.keys[f]; var row=byName[name]||{}; var val=row.value; var editing=S.cfgEdit&&S.cfgEdit.name===name;
    s+='<div class="cfg-field"><div class="fname">'+esc(name)
      +(row.desc?'<div class="fdesc">'+esc(row.desc)+'</div>':'')
      +'</div><div class="cfg-val">';
    if(editing){
      if(row.options&&row.options.length){
        // Closed value set: a select instead of free text. The current value is
        // preselected; a legacy value outside today's set is kept as a visible
        // extra option so the select never lies about what is on disk.
        s+='<select class="cfg-in" data-cfg-input aria-label="'+esc(name)+' value">';
        var opts=row.options.slice(); var cur=(S.cfgEdit.buffer||'');
        if(cur&&opts.indexOf(cur)<0) opts.push(cur);
        for(var o=0;o<opts.length;o++) s+='<option value="'+esc(opts[o])+'"'+(opts[o]===cur?' selected':'')+'>'+esc(opts[o])+'</option>';
        s+='</select>';
      } else {
        s+='<input class="cfg-in" data-cfg-input aria-label="'+esc(name)+' value" autocomplete="off" spellcheck="false"'+(row.numeric?' inputmode="numeric"':'')+'>';
      }
      s+='<button class="btn sm primary" data-cfg-save="'+esc(name)+'">Save…</button>';
      s+='<button class="btn sm" data-cfg-cancel>Cancel</button>';
      if(S.cfgErr&&S.cfgErr.name===name) s+='<span class="cfg-err">'+esc(S.cfgErr.text)+'</span>';
    } else {
      s+=(val?'<span>'+esc(val)+'</span>':'<span class="muted">(unset)</span>');
      s+='<button class="btn sm" data-cfg-edit="'+esc(name)+'">Edit</button>';
    }
    s+='</div></div>';
  }
  if(chosen.id==='learning') s+=cadenceRows();
  }
  var log=(S.page.log)||[];
  if(log.length){ s+='<div class="receipts"><div class="muted" style="font-size:12px;margin-bottom:4px">Recent writes (.dash-edits.log)</div>';
    for(var l=log.length-1;l>=0&&l>=log.length-8;l--) s+='<div class="rc">'+esc(log[l])+'</div>';
    s+='</div>';
  }
  s+='</div></div>';
  return s;
}

// ---- Crew dispatch (dash-crew-dispatch): read-only rule view + raw-JSON editor ----
function useSummary(use){
  if(use==null) return '<span class="muted">(no profile)</span>';
  var arr=(Object.prototype.toString.call(use)==='[object Array]')?use:[use];
  var parts=[];
  for(var i=0;i<arr.length;i++){ var u=arr[i]||{}; var t=esc(u.harness||'?'); if(u.model) t+=' &middot; '+esc(u.model); if(u.effort) t+=' &middot; '+esc(u.effort); parts.push('<span class="mono">'+t+'</span>'); }
  return parts.join(' <span class="muted">/</span> ');
}
var provC=null, provBusy=false;
function loadProviders(){
  if(provBusy) return; provBusy=true;
  fetch('/api/providers?path='+enc((S.route&&S.route.home&&S.route.home.path)||'')).then(function(r){ return r.json(); }).then(function(j){
    provC=j; provBusy=false; if(S.route&&S.route.name==='config') renderPage();
  }).catch(function(){ provBusy=false; });
}
function providersPanel(){
  if(!provC){ loadProviders(); return skeleton(); }
  var s='<div class="cfg-note">Two lanes, each on its own provider and key: <b>Embedding</b> powers semantic search (a model change needs a rebuild), <b>Synthesize</b> powers Ask (LLM). A save writes ONLY its own lane. Keys live in this home\u2019s <code>config/providers.json</code> (0600, never in the repo); an env var on the host overrides.</div>';
  s+=provLaneCard('embedding','Embedding',(provC.lanes&&provC.lanes.embedding)||[],provC.embedding||null);
  s+=provLaneCard('synthesize','Synthesize',(provC.lanes&&provC.lanes.synthesize)||[],provC.synthesize||null);
  if(provC.warn) s+='<div class="badge warn" style="margin-top:8px">'+esc(provC.warn)+'</div>';
  return s;
}
function provLaneCard(lane,label,rows,curCfg){
  var sel=(S.provSel&&S.provSel[lane])||(curCfg&&curCfg.provider)||(rows[0]&&rows[0].name)||'';
  var cur=null; for(var i=0;i<rows.length;i++){ if(rows[i].name===sel) cur=rows[i]; }
  var s='<div class="cfg-field"><div class="fname">'+esc(label)
    +(curCfg?'<div class="fdesc">now: '+esc(curCfg.provider)+' / '+esc(curCfg.model||'')+'</div>':'')
    +'</div><div class="cfg-val" style="flex-wrap:wrap;row-gap:6px">';
  s+='<select class="cfg-in" data-prov-sel="'+lane+'" aria-label="'+esc(label)+' provider">';
  for(var i=0;i<rows.length;i++){ var pv=rows[i];
    s+='<option value="'+esc(pv.name)+'"'+(pv.name===sel?' selected':'')
      +'>'+esc(pv.name)+(curCfg&&curCfg.provider===pv.name?' (active)':'')+'</option>';
  }
  s+='</select>';
  if(cur){
    var mkey=lane+'|'+cur.name;
    var curModel=(provDraft['m:'+mkey]!==undefined)?provDraft['m:'+mkey]
      :(curCfg&&curCfg.provider===cur.name&&curCfg.model)||cur.dflt;
    if(lane==='embedding'){
      // Closed set: dims ride the model, so free text cannot be honored here.
      s+=' <select class="cfg-in" data-prov-model="'+mkey+'" aria-label="'+esc(label)+' model">';
      var ms=cur.models||[];
      for(var m=0;m<ms.length;m++) s+='<option value="'+esc(ms[m])+'"'+(ms[m]===curModel?' selected':'')+'>'+esc(ms[m])+'</option>';
      s+='</select>';
    } else {
      var listId='provml-'+cur.name;
      s+=' <input class="cfg-in" list="'+listId+'" value="'+esc(curModel)+'" data-prov-model="'+mkey+'" aria-label="'+esc(label)+' model" spellcheck="false" style="width:210px">';
      s+='<datalist id="'+listId+'">';
      var live=provModels[cur.name]||[];
      for(var m=0;m<live.length;m++) s+='<option value="'+esc(live[m])+'">';
      s+='</datalist>';
      if(provModels[cur.name]===undefined) loadProvModels(cur.name);
    }
    var st = cur.no_key ? '<span class="badge ok">no key needed (local)</span>'
      : cur.source==='env' ? '<span class="badge ok">env '+esc(cur.env)+'</span>'
      : cur.source==='file' ? '<span class="badge ok">key '+esc(cur.masked||'')+'</span>'
      : '<span class="badge">no key yet</span>';
    s+=' '+st;
    if(!cur.no_key) s+=' <input class="cfg-in" type="password" placeholder="'+(cur.source?'key saved - paste to replace':'paste key')+'" aria-label="'+esc(label)+' API key" autocomplete="new-password" spellcheck="false" data-prov-input="'+mkey+'" style="width:190px">';
    s+=' <button class="btn sm primary" data-prov-save="'+mkey+'">Save '+lane+'</button>';
  }
  s+='</div></div>';
  return s;
}
var provDraft={}, provModels={}, provModelsBusy={};
function loadProvModels(name){
  if(provModelsBusy[name]) return; provModelsBusy[name]=true;
  fetch('/api/provider-models?path='+enc((S.route&&S.route.home&&S.route.home.path)||'')+'&provider='+enc(name))
    .then(function(r){ return r.json(); }).then(function(j){
      provModels[name]=(j&&j.models)||[]; provModelsBusy[name]=false;
      if(S.route&&S.route.name==='config') renderPage();
    }).catch(function(){ provModels[name]=[]; provModelsBusy[name]=false; });
}
function provSave(ref){
  var i=ref.indexOf('|'), lane=ref.slice(0,i), name=ref.slice(i+1);
  var body={ lane:lane, provider:name };
  var mel=document.querySelector('[data-prov-model="'+ref+'"]');
  if(mel&&mel.value) body.model=mel.value;
  if(provDraft[ref]) body.api_key=provDraft[ref];
  fetch('/api/providers?path='+enc((S.route&&S.route.home&&S.route.home.path)||''), { method:'POST', headers:{'Content-Type':'application/json'},
    body: JSON.stringify(body) }).then(function(r){ return r.json(); }).then(function(j){
    provC=j; provDraft[ref]=''; delete provDraft['m:'+ref]; renderPage();
  }).catch(function(){});
}
function dispatchPanel(){
  var d=(S.page&&S.page.dispatch)||{exists:false,raw:'',rules:[],dflt:null,panes:[],error:null};
  var s='';
  s+='<div class="cfg-note">The spawn dispatch table: a prose <span class="mono">when</span> clause routes a task to a <span class="mono">harness / model / effort</span> profile (<span class="mono">ac-dispatch-select.sh</span>). Read-only below; edit the whole document with the button.</div>';
  if(!d.exists) s+='<div class="cfg-note">No <span class="mono">crew-dispatch.json</span> yet &mdash; spawn falls back to <span class="mono">config/crew-harness</span> (default claude).</div>';
  if(d.error) s+='<div class="badge err" style="margin:8px 0">crew-dispatch.json is invalid ('+esc(d.error)+') &mdash; fix it in the editor.</div>';
  if(S.dispMsg) s+='<div class="'+(S.dispMsg.ok?'badge ok':'badge err')+'" style="margin:8px 0">'+esc(S.dispMsg.text)+'</div>';
  if(d.rules&&d.rules.length){
    s+='<div class="disp-rules">';
    for(var i=0;i<d.rules.length;i++){ var r=d.rules[i];
      s+='<div class="disp-rule"><div class="disp-h"><span class="badge accent">rule '+(i+1)+'</span> '+useSummary(r.use)+'</div>';
      s+='<div class="disp-when">'+esc(r.when)+'</div>';
      if(r.why) s+='<div class="disp-why">'+esc(r.why)+'</div>';
      s+='</div>';
    }
    if(d.dflt!=null) s+='<div class="disp-rule"><div class="disp-h"><span class="badge">default</span> '+useSummary(d.dflt)+'</div></div>';
    s+='</div>';
  }
  if(d.panes&&d.panes.length){
    s+='<div class="cfg-note" style="margin-top:12px">Pane profiles &mdash; static entries resolve by kind. Routed rules (qa/gate/codereview/roomchief) are caller-judged from their numbered <span class="mono">when / use / why</span> cards before the pane exists; the bare default is separate (optional for qa, mandatory for the rest).</div>';
    s+='<div class="disp-rules">';
    for(var j=0;j<d.panes.length;j++){ var p=d.panes[j];
      if(p.routed){
        for(var k=0;k<p.rules.length;k++){ var qr=p.rules[k];
          s+='<div class="disp-rule"><div class="disp-h"><span class="badge accent">pane &middot; '+esc(p.kind)+' &middot; rule '+(k+1)+'</span> '+useSummary(qr.use)+'</div>';
          s+='<div class="disp-when">'+esc(qr.when)+'</div><div class="disp-why">'+esc(qr.why)+'</div></div>';
        }
        if(p.dflt!=null) s+='<div class="disp-rule"><div class="disp-h"><span class="badge">pane &middot; '+esc(p.kind)+' &middot; default</span> '+useSummary(p.dflt)+'</div></div>';
      } else {
        s+='<div class="disp-rule"><div class="disp-h"><span class="badge">pane &middot; '+esc(p.kind)+'</span> '+useSummary(p.use)+'</div></div>';
      }
    }
    s+='</div>';
  }
  if(S.dispEdit){
    s+='<div class="cfg-note" style="margin-top:12px">Validated before write: valid JSON, a non-empty <span class="mono">rules[]</span>, and each rule a <span class="mono">when</span> + a <span class="mono">use</span> naming a harness. A receipt goes to <span class="mono">.dash-edits.log</span>.</div>';
    s+='<textarea class="disp-ta" data-disp-input spellcheck="false" aria-label="crew-dispatch.json"></textarea>';
    if(S.dispErr) s+='<div class="cfg-err" style="display:block;margin:6px 0">'+esc(S.dispErr)+'</div>';
    s+='<div style="margin-top:8px"><button class="btn sm primary" data-disp-save>Save…</button> <button class="btn sm" data-disp-cancel>Cancel</button></div>';
  } else {
    s+='<div style="margin-top:12px"><button class="btn sm" data-disp-edit>'+(d.exists?'Edit JSON':'Create crew-dispatch.json')+'</button></div>';
  }
  return s;
}
function dispTemplate(){
  return JSON.stringify({ rules:[ { when:'describe when this rule applies', use:{ harness:'claude', model:'opus', effort:'high' }, why:'why this profile fits' } ] }, null, 2);
}
function dispStartEdit(){
  var d=(S.page&&S.page.dispatch)||{}; S.dispEdit={ buffer:(d.raw&&d.raw.trim())?d.raw:dispTemplate() }; S.dispErr=null; S.dispMsg=null; renderPage();
}
function dispCancel(){ S.dispEdit=null; S.dispErr=null; renderPage(); }
function dispSave(){
  if(!S.dispEdit) return;
  var raw=S.dispEdit.buffer||'';
  try{ JSON.parse(raw); }catch(err){ S.dispErr='invalid JSON: '+err.message; renderPage(); return; }
  var fleet=S.route.fleet;
  var body='<div class="dl">'+esc(fleet)+'/config/crew-dispatch.json will be replaced.</div>';
  body+='<div class="eff">Spawn dispatch for future tasks uses the new rules. The document is re-validated server-side before it is written.</div>';
  openDialog({ title:'Confirm crew-dispatch.json', body:body, confirmLabel:'Confirm and save', onConfirm:function(){ closeDialog(); dispWrite(raw); } });
}
function dispWrite(raw){
  S.dispEdit=null; S.dispMsg={ok:true,text:'writing…'}; renderPage();
  fetch('/api/dispatch?path='+enc(S.route.home.path), { method:'POST', headers:{'content-type':'text/plain'}, body:raw })
    .then(function(r){ return r.json().then(function(j){ return {ok:r.ok, j:j}; }); })
    .then(function(res){
      if(res.ok && res.j.receipt) S.dispMsg={ok:true, text:'saved · '+res.j.receipt};
      else S.dispMsg={ok:false, text:'refused: '+((res.j&&res.j.error)||'failed')};
      renderPage(); pollRoute(true);
    })
    .catch(function(){ S.dispMsg={ok:false, text:'unreachable — no change written'}; renderPage(); });
}

/* The learning-loop COUNTERS for the selected fleet, next to the two knobs that
   set their thresholds. Read-only on purpose: a counter is not a knob, so the
   write surface stays the existing learn-every/curate-every keys. Every number,
   and the DUE flag itself, comes from the snapshot's per-home cadence block
   (ac-fleets.sh) - no threshold is re-derived here. */
function cadenceRows(){
  var h=S.route&&S.route.home, c=h&&h.cadence;
  if(!c) return '';
  var s='<div class="cfg-note" style="margin-top:16px">Counters for <b>'+esc(S.route.fleet)+'</b> — read-only; the session-start digest reads the same two.</div>';
  s+=cadRow('debriefs', c.learn);
  s+=cadRow('runs_since', c.curate);
  var lr=c.learn&&c.learn.last_run;
  s+='<div class="cfg-field"><div class="fname">last_run</div><div class="cfg-val">'
    +(lr?'<span>'+esc(agoMs(lr*1000))+'</span>':'<span class="muted">(never)</span>')+'</div></div>';
  return s;
}
function cadRow(name, o){
  if(!o) return '';
  return '<div class="cfg-field"><div class="fname">'+name+'</div><div class="cfg-val"><span>'
    +o.count+' / '+o.every+'</span>'+(o.due?'<span class="badge warn">DUE</span>':'')+'</div></div>';
}

function chip(id, label, active){ return '<button class="chip" data-chip="'+id+'" aria-pressed="'+(active===id?'true':'false')+'">'+esc(label)+'</button>'; }

// ===========================================================================
// Room narrative (lazy, cached) - used by the Processes inbox disclosure.
// ===========================================================================
var roomCache={}, roomLoading={};
function loadRoom(fam){
  var hp=S.route.home?S.route.home.path:''; var ck=hp+'|'+fam;
  if((ck in roomCache) || roomLoading[ck]) return;
  roomLoading[ck]=1;
  fetch('/api/room?path='+enc(hp)+'&family='+enc(fam)).then(function(r){ return r.json(); }).then(function(j){
    delete roomLoading[ck]; roomCache[ck]=(j.entries||[]); renderPage();
  }).catch(function(){ delete roomLoading[ck]; roomCache[ck]=['(failed to load)']; renderPage(); });
}

// ===========================================================================
// Config editing -> confirmation dialog -> write (the one mutation surface).
// ===========================================================================
function startEdit(name){
  var cur='', row=null; var ed=(S.page&&S.page.editable)||[];
  for(var i=0;i<ed.length;i++){ if(ed[i].name===name){ cur=ed[i].value; row=ed[i]; } }
  // A select has no empty row: an unset enum knob starts on the first option, so
  // what the captain SEES selected is exactly what Save… will write.
  if(!cur && row && row.options && row.options.length) cur=row.options[0];
  S.cfgEdit={name:name, buffer:cur, old:(row?row.value:'')}; S.cfgErr=null; S.cfgMsg=null;
  renderHead(); renderPage();
}
function cancelEdit(){ S.cfgEdit=null; S.cfgErr=null; renderHead(); renderPage(); }
function saveEdit(name){
  if(!S.cfgEdit || S.cfgEdit.name!==name) return;
  var val=(S.cfgEdit.buffer||'').trim();
  if(!val){ S.cfgErr={name:name, text:'value must be non-empty'}; renderPage(); return; }
  if(val.indexOf('\\n')>=0 || val.indexOf('\\r')>=0){ S.cfgErr={name:name, text:'value must be a single line'}; renderPage(); return; }
  var old=S.cfgEdit.old, fleet=S.route.fleet;
  var body='<div class="dl">'+esc(fleet)+'/config/'+esc(name)+': <span class="o">'+(old?esc(old):'(unset)')+'</span> &rarr; <span class="nv">'+esc(val)+'</span></div>';
  body+='<div class="eff">This affects future sessions of fleet '+esc(fleet)+'.</div>';
  openDialog({ title:'Confirm configuration change', body:body, confirmLabel:'Confirm and save',
    onConfirm:function(){ closeDialog(); doWrite(name, val); } });
}
function doWrite(name, val){
  S.cfgEdit=null; S.cfgMsg={ok:true, text:'writing…'}; renderHead(); renderPage();
  fetch('/api/config?path='+enc(S.route.home.path)+'&file='+enc(name), { method:'POST', headers:{'content-type':'text/plain'}, body:val })
    .then(function(r){ return r.json().then(function(j){ return {ok:r.ok, j:j}; }); })
    .then(function(res){
      if(res.ok && res.j.receipt) S.cfgMsg={ok:true, text:'saved · '+res.j.receipt};
      else S.cfgMsg={ok:false, text:'refused: '+((res.j&&res.j.error)||'failed')};
      renderPage(); pollRoute(true);
    })
    .catch(function(){ S.cfgMsg={ok:false, text:'unreachable — no change written'}; renderPage(); });
}
// ===========================================================================
// Modal dialog with focus trap (WAI-ARIA dialog pattern).
// ===========================================================================
function openDialog(opts){
  S.dlg=opts; S.dlgPrev=document.activeElement;
  var root=el('dialog-root');
  var h='<div class="backdrop" data-dlg-backdrop><div class="dialog" role="dialog" aria-modal="true" aria-labelledby="dlg-title">';
  h+='<h2 id="dlg-title">'+esc(opts.title)+'</h2>'+opts.body;
  h+='<div class="dbtns"><button type="button" class="btn" data-dlg-cancel>Cancel</button><button type="button" class="btn primary" data-dlg-confirm>'+esc(opts.confirmLabel||'Confirm')+'</button></div>';
  h+='</div></div>';
  root.innerHTML=h;
  var dlg=root.querySelector('.dialog');
  dlg.addEventListener('keydown', dlgKeydown);
  var cf=root.querySelector('[data-dlg-confirm]'); if(cf) cf.focus();
}
function closeDialog(){
  el('dialog-root').innerHTML=''; S.dlg=null;
  if(S.dlgPrev && S.dlgPrev.focus){ try{ S.dlgPrev.focus(); }catch(e){} }
  S.dlgPrev=null;
}
function dlgKeydown(e){
  if(e.key==='Escape'){ e.preventDefault(); closeDialog(); return; }
  if(e.key!=='Tab') return;
  var f=el('dialog-root').querySelectorAll('button, [href], input, select, textarea, [tabindex]');
  var list=[]; for(var i=0;i<f.length;i++){ if(!f[i].disabled && f[i].offsetParent!==null) list.push(f[i]); }
  if(!list.length) return;
  var first=list[0], last=list[list.length-1], a=document.activeElement;
  if(e.shiftKey && a===first){ e.preventDefault(); last.focus(); }
  else if(!e.shiftKey && a===last){ e.preventDefault(); first.focus(); }
}

// ===========================================================================
// Post-render passes: iframe identity, input value/caret, scroll restore.
// ===========================================================================
// Mermaid pass for the md reader: our renderer emits
// language-mermaid fences as escaped code; this pass lazy-loads mermaid from
// the CDN ONCE and swaps each fence for its rendered SVG. Safe because the
// source text ran through the escaping renderer - the only script here is
// the one we import. The vbody is a data-preserve island, so rendered SVGs
// survive polling; a new selection re-runs the pass on fresh content.
var mermaidMod=null, mermaidLoading=false;
function postMermaid(){
  var v=S.viewer; if(!v || v.kind!=='md') return;
  var blocks=document.querySelectorAll('.reader pre > code[class*=language-mermaid]');
  if(!blocks.length) return;
  if(!mermaidMod){
    if(mermaidLoading) return;
    mermaidLoading=true;
    import('https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs').then(function(m){
      mermaidMod=m.default; mermaidMod.initialize({ startOnLoad:false, theme:'dark' });
      mermaidLoading=false; postMermaid();
    }).catch(function(){ mermaidLoading=false; });
    return;
  }
  for(var i=0;i<blocks.length;i++){ (function(code, i){
    var pre=code.closest('pre'); if(!pre || pre.getAttribute('data-mmd')) return;
    pre.setAttribute('data-mmd','1');
    mermaidMod.render('mmd'+String(Math.abs(('' + code.textContent).length))+'x'+i+'g'+(S.viewer&&S.viewer.gen||0), code.textContent).then(function(r){
      var d=document.createElement('div');
      d.className='mmdview'; d.innerHTML=r.svg;
      var keep=pre.getAttribute('data-srcline'); if(keep) d.setAttribute('data-srcline', keep);
      if(pre.parentNode) pre.replaceWith(d);
    }).catch(function(){ pre.setAttribute('data-mmd','err'); });
  })(blocks[i], i); }
}

function postFrames(){
  var f=el('viewer-frame');
  if(f){ var v=S.viewer; if(v && v.kind==='html' && v.content!=null){ var sig=v.key+'#'+(v.gen||0);
    // Mount the sandboxed document exactly once per (selection, gen). The empty
    // sandbox denies script/form/popup/download/top-nav/same-origin. Because the
    // vbody is a data-preserve island, morph never strips these back off on poll.
    if(f._loaded!==sig){ f.setAttribute('sandbox',''); f.srcdoc=v.content; f._loaded=sig; } } }
  postMermaid();
  postInputs();
}
function postInputs(){
  var rk = S.route?routeKey(S.route):'x';
  var lst=document.querySelectorAll('[data-list-search]');
  for(var i=0;i<lst.length;i++){ var inp=lst[i]; if(inp._acKey!==rk){ inp.value=uiFor(rk).query; inp._acKey=rk; } }
  var sp=document.querySelector('[data-search-page]');
  if(sp && sp._acKey!=='search'){ sp.value=uiFor('search').query; sp._acKey='search'; }
  var cin=document.querySelector('[data-cfg-input]');
  if(cin){ var ek=(S.cfgEdit&&S.cfgEdit.name)||''; if(cin._acEdit!==ek){ cin.value=(S.cfgEdit?S.cfgEdit.buffer:''); cin._acEdit=ek;
    cin.focus(); var L=cin.value.length; try{ cin.setSelectionRange(L,L); }catch(e){} } }
  // The dispatch editor is a single textarea; set its value only on a fresh mount
  // (buffer is kept current by onInput), so a poll re-render never eats a keystroke.
  var din=document.querySelector('[data-disp-input]');
  if(din){ var dk=S.dispEdit?'1':''; if(din._acDisp!==dk){ din.value=(S.dispEdit?S.dispEdit.buffer:''); din._acDisp=dk;
    if(S.dispEdit){ din.focus(); var DL=din.value.length; try{ din.setSelectionRange(DL,DL); }catch(e){} } } }
}
function saveScroll(){
  if(!S.route) return; var ui=uiFor(routeKey(S.route));
  ui.pageScroll=window.scrollY||window.pageYOffset||0;
  var l=document.querySelector('[data-listscroll]'); if(l) ui.listScroll=l.scrollTop;
  var v=document.querySelector('[data-viewerscroll]'); if(v) ui.viewerScroll=v.scrollTop;
}
function restoreScroll(){
  if(!S.route) return; var ui=uiFor(routeKey(S.route));
  requestAnimationFrame(function(){
    window.scrollTo(0, ui.pageScroll||0);
    var l=document.querySelector('[data-listscroll]'); if(l) l.scrollTop=ui.listScroll||0;
    var v=document.querySelector('[data-viewerscroll]'); if(v) v.scrollTop=ui.viewerScroll||0;
  });
}
function toggleSidebar(){
  var c=!document.body.classList.contains('sb-collapsed');
  document.body.classList.toggle('sb-collapsed', c);
  el('collapse-btn').setAttribute('aria-pressed', c?'true':'false');
  try{ localStorage.setItem('ac_dash_sb', c?'1':'0'); }catch(e){}
}
function defOpenOf(dk){ return dk==='sec:inflight'||dk==='sec:queued'; }
function toggleDisc(dk){ var ui=uiFor(routeKey(S.route)); var cur=(dk in ui.exp)?ui.exp[dk]:defOpenOf(dk); ui.exp[dk]=!cur; renderPage(); }

// ===========================================================================
// Event delegation
// ===========================================================================
function onClick(e){
  var x0=e.target&&e.target.closest?e.target.closest('[data-ext]'):null;
  if(x0){ window.open(x0.getAttribute('data-ext'),'_blank','noopener'); e.preventDefault(); e.stopPropagation(); return; }
  var t=e.target; if(!t) return; if(t.nodeType===3) t=t.parentElement; if(!t||!t.closest) return;
  var n;
  if(t.closest('#refresh-btn')){ tick(true); return; }
  if((n=t.closest('[data-chief-key]'))){ chiefKey(n.getAttribute('data-chief-key')); return; }
  if((n=t.closest('[data-chief-watch]'))!==null && n){ chiefSetWatch(n.getAttribute('data-chief-watch')); return; }
  if(t.closest('#chief-term')){
    // A linkified URL inside the pane wins over type-through arming: open it
    // (scheme re-checked; opener severed) instead of focusing the IME.
    var pl=t.closest('a[target="_blank"]');
    if(pl){ var pu=pl.getAttribute('href')||''; if(/^https?:$/i.test(pu.split('//')[0])){ e.preventDefault(); var pw=null; try{ pw=window.open(pu,'_blank'); }catch(err){} if(pw){ try{ pw.opener=null; }catch(err){} } } return; }
    if(!chiefKb) chiefKbToggle(); var im0=el('chief-ime'); if(im0) im0.focus(); return; }
  if(t.closest('#chief-compose')){ chiefComposeToggle(); return; }
  if(t.closest('#chief-send')){ chiefSendMsg(); return; }
  if(t.closest('#chief-kb')){ chiefKbToggle(); return; }
  if(t.closest('#theme-btn')){ toggleTheme(); return; }
  if(t.closest('#palette-btn')){ togglePalette(); return; }
  if(t.closest('#bg-btn')){ openBgDialog(); return; }
  if(t.closest('#collapse-btn')){ toggleSidebar(); return; }
  // New-tab chat/terminal chips: open PROGRAMMATICALLY instead of trusting the
  // anchor default - in the captain's real Chrome the default was observed
  // swallowed (anchor focused, tooltip up, no navigation; headless clicks
  // navigated fine), and window.open on a trusted click is immune to whatever
  // ate it. The anchor markup stays for middle-click/copy-link semantics.
  var nt=t.closest('a[target="_blank"]');
  if(nt && e.button===0 && !e.metaKey && !e.ctrlKey && !e.shiftKey && !e.altKey){
    var nh=nt.getAttribute('href');
    if(nh && nh.charAt(0)==='/'){
      e.preventDefault();
      // window.open returns null when a popup blocker (browser or extension)
      // eats it - fall back to SAME-TAB navigation, because a click that does
      // nothing is the one unacceptable outcome. Back button returns. NO
      // 'noopener' in the features string: the spec makes open() return null
      // for it even on success, which would double-fire the fallback; the
      // opener is severed on the handle instead (same-origin pages anyway).
      var ntw=null; try{ ntw=window.open(nh, '_blank'); }catch(err){}
      if(ntw){ try{ ntw.opener=null; }catch(err){} }
      else if(parseRoute(nh).name!=='notfound') navigate(nh);
      return;
    }
  }
  var lnk=t.closest('a[data-link], a[data-nav]');
  if(lnk){
    if(e.button===0 && !e.metaKey && !e.ctrlKey && !e.shiftKey && !e.altKey){
      var href=lnk.getAttribute('href');
      if(href && href.charAt(0)==='/'){
        e.preventDefault();
        var jq=lnk.getAttribute('data-jumpq');
        if(jq){ var rr=parseRoute(href); if(rr.fleet){ var uk=uiFor(rr.name+':'+rr.fleet); uk.query=jq; uk.filter='all'; } }
        navigate(href);
      }
    }
    return;
  }
  if((n=t.closest('[data-chip]'))){ var uf=uiFor(routeKey(S.route)); uf.filter=n.getAttribute('data-chip');
    // A narrowed Reports list re-derives its tree defaults (every hit visible).
    if(S.route.name==='reports') uf.exp={}; renderPage(); return; }
  if((n=t.closest('[data-rview]'))){ try{ localStorage.setItem('ac_dash_rview', n.getAttribute('data-rview')); }catch(e){} renderPage(); return; }
  if((n=t.closest('[data-board-hidedone]'))){ toggleHideDone(); return; }
  if((n=t.closest('[data-reviews-active]'))){ toggleReviewsActive(); return; }
  if((n=t.closest('[data-review-end]'))){ reviewRowEnd(n.getAttribute('data-review-end'), n.getAttribute('data-review-end-file'), false); return; }
  if((n=t.closest('[data-review-reopen]'))){ reviewRowEnd(n.getAttribute('data-review-reopen'), n.getAttribute('data-review-reopen-file'), true); return; }
  if((n=t.closest('[data-stop-share]'))){ stopShare(n.getAttribute('data-stop-share'), n.getAttribute('data-stop-share-file')); return; }
  if((n=t.closest('[data-reveal]'))){ fetch('/api/reveal?path='+enc(n.getAttribute('data-reveal'))+'&file='+enc(n.getAttribute('data-reveal-file')),{method:'POST'}).catch(function(){}); return; }
  if((n=t.closest('[data-board-timeline]'))){ boardShowTimeline(); return; }   // render the lifecycle timeline in the viewer
  if((n=t.closest('[data-board-room]'))){ boardShowRoom(); return; }           // render the family room in the viewer (room-in-viewer)
  if((n=t.closest('[data-board-overview]'))){ boardShowOverview(); return; }   // back from room/timeline/artifact to the overview
  if((n=t.closest('[data-board-art]'))){ boardOpenArt(n); return; }   // load artifact inline (detail viewer)
  if((n=t.closest('[data-stage-toggle]'))){ var box2=n.closest('.stage,.story'); if(box2) box2.classList.toggle('collapsed'); return; }
  if((n=t.closest('[data-tool-open]'))){
    toolOpen(n.getAttribute('data-tool-open'), n.getAttribute('data-tool-title')||'');
    return;
  }
  if(t.closest('#tool-close')){ toolClose(); return; }
  if((n=t.closest('[data-reports-all]'))){ uiFor(routeKey(S.route)).showAll=true; pollRoute(true); return; }
  if((n=t.closest('[data-wb-rename-cancel]'))){
    var uiC=uiFor(routeKey(S.route)); uiC.wbRenaming=null; uiC.wbRenameDraft='';
    renderPage(); return;
  }
  if((n=t.closest('[data-wb-rename-do]'))){
    var uiD=uiFor(routeKey(S.route));
    var toName=(uiD.wbRenameDraft||'').trim();
    if(!/^[a-z0-9][a-z0-9-]{0,63}$/.test(toName)){ var ri=document.querySelector('[data-wb-rename-input]'); if(ri){ ri.focus(); ri.setAttribute('aria-invalid','true'); } return; }
    var rnR=S.route;
    if(rnR&&rnR.home){
      fetch('/api/whiteboard?path='+enc(rnR.home.path)+'&scene='+enc(n.getAttribute('data-wb-rename-do'))+'&rename='+enc(toName), { method:'POST' })
        .then(function(res){ return res.json(); })
        .then(function(j){ if(j&&j.ok){ uiD.wbRenaming=null; uiD.wbRenameDraft=''; } pollRoute(true); });
    }
    return;
  }
  if((n=t.closest('[data-wb-rename]'))){
    var uiR=uiFor(routeKey(S.route)); uiR.wbRenaming=n.getAttribute('data-wb-rename'); uiR.wbRenameDraft=n.getAttribute('data-wb-rename');
    renderPage(); return;
  }
  if((n=t.closest('[data-wb-del]'))){
    // Two-step confirm, never a blocking dialog: first click arms the button,
    // the second click (before any re-render resets it) deletes.
    if(n.getAttribute('data-armed')!=='1'){ n.setAttribute('data-armed','1'); n.textContent='Confirm delete'; return; }
    var delR=S.route;
    if(delR&&delR.home){
      fetch('/api/whiteboard?path='+enc(delR.home.path)+'&scene='+enc(n.getAttribute('data-wb-del')), { method:'DELETE' })
        .then(function(){ pollRoute(true); });
    }
    return;
  }
  if((n=t.closest('[data-wb-open]'))){
    var wbIn=document.querySelector('[data-wb-new]');
    var wbName=(wbIn&&wbIn.value||'').trim();
    var wbR=S.route;
    // Same grammar the server enforces (isSceneName) - refuse client-side so
    // the editor never opens on a name the save would then 400 on.
    if(!/^[a-z0-9][a-z0-9-]{0,63}$/.test(wbName)){ if(wbIn){ wbIn.focus(); wbIn.setAttribute('aria-invalid','true'); } return; }
    if(wbR&&wbR.home) toolOpen('/whiteboard?path='+enc(wbR.home.path)+'&scene='+enc(wbName), 'whiteboard \u00b7 '+wbName);
    return;
  }
  if((n=t.closest('[data-tree]'))){ var tk='tree:'+n.getAttribute('data-tree'); var ut=uiFor(routeKey(S.route));
    // The rendered aria-expanded IS the current state, defaults included.
    ut.exp[tk]=(n.getAttribute('aria-expanded')!=='true'); renderPage(); return; }
  if((n=t.closest('[data-learning-view]'))){ var uv=uiFor(routeKey(S.route)); uv.sec.learning=n.getAttribute('data-learning-view'); renderPage(); return; }
  if((n=t.closest('[data-sort]'))){ var sk=n.getAttribute('data-sort'); var us=uiFor(routeKey(S.route));
    if(us.sort===sk) us.sortDir=(us.sortDir||1)*-1; else { us.sort=sk; us.sortDir=1; } renderPage(); return; }
  if((n=t.closest('[data-disc]'))){ toggleDisc(n.getAttribute('data-disc')); return; }
  if((n=t.closest('[data-exprow]'))){ var rk=n.getAttribute('data-exprow'); var ui2=uiFor(routeKey(S.route));
    ui2.exp[rk]=!ui2.exp[rk]; if(ui2.exp[rk] && rk.indexOf('room:')===0) loadRoom(rk.slice(5)); renderPage(); return; }
  if((n=t.closest('[data-cfg-section]'))){ S.cfgSection=n.getAttribute('data-cfg-section'); renderPage(); return; }
  if((n=t.closest('[data-cfg-edit]'))){ startEdit(n.getAttribute('data-cfg-edit')); return; }
  if((n=t.closest('[data-cfg-save]'))){ saveEdit(n.getAttribute('data-cfg-save')); return; }
  if(t.closest('[data-cfg-cancel]')){ cancelEdit(); return; }
  if(t.closest('[data-brain-go]')){ brainRes=null; brainSearch(); renderPage(); return; }
  if(t.closest('[data-brain-ask]')){ brainAsk(); return; }
  if((n=t.closest('[data-prov-save]'))){ provSave(n.getAttribute('data-prov-save')); return; }
  if(t.closest('[data-disp-edit]')){ dispStartEdit(); return; }
  if(t.closest('[data-disp-save]')){ dispSave(); return; }
  if(t.closest('[data-disp-cancel]')){ dispCancel(); return; }
  if(t.closest('[data-reload]')){ reloadViewer(); return; }
  if(t.closest('[data-dlg-confirm]')){ if(S.dlg&&S.dlg.onConfirm) S.dlg.onConfirm(); return; }
  if(t.closest('[data-dlg-cancel]')){ closeDialog(); return; }
  if(t.hasAttribute && t.hasAttribute('data-dlg-backdrop')){ closeDialog(); return; }
}
function onInput(e){
  var t=e.target; if(!t||!t.hasAttribute) return;
  if(t.hasAttribute('data-cfg-input')){ if(S.cfgEdit) S.cfgEdit.buffer=t.value; return; }
  if(t.hasAttribute('data-disp-input')){ if(S.dispEdit) S.dispEdit.buffer=t.value; return; }
  if(t.hasAttribute('data-prov-input')){ provDraft[t.getAttribute('data-prov-input')]=t.value; return; }
  if(t.hasAttribute('data-prov-model')){ provDraft['m:'+t.getAttribute('data-prov-model')]=t.value; return; }
  if(t.hasAttribute&&t.hasAttribute('data-prov-sel')){ S.provSel=S.provSel||{}; S.provSel[t.getAttribute('data-prov-sel')]=t.value; renderPage(); return; }
  if(t.hasAttribute('data-brain-q')){ brainQ[(S.route&&S.route.home&&S.route.home.path)||'']=t.value;
    if(brainTimer) clearTimeout(brainTimer); brainTimer=setTimeout(function(){ brainRes=null; brainSearch(); }, 400); return; }
  if(t.hasAttribute('data-wb-rename-input')){ uiFor(routeKey(S.route)).wbRenameDraft=t.value; return; }
  if(t.hasAttribute('data-list-search')){ var ul=uiFor(routeKey(S.route)); ul.query=t.value;
    if(S.route.name==='reports'){ ul.exp={};
      // A search must scan the WHOLE list: a partial first page silently
      // hiding matches would read as "not found" - refetch full once.
      if(S.page && S.page.total && S.page.artifacts && S.page.total>S.page.artifacts.length) pollRoute(true);
    }
    renderPage(); return; }
  if(t.hasAttribute('data-search-page')){ uiFor('search').query=t.value; if(searchTimer) clearTimeout(searchTimer); searchTimer=setTimeout(runSearch, 250); renderPage(); return; }
}

// ===========================================================================
// Boot
// ===========================================================================
function boot(){
  try{ if(localStorage.getItem('ac_dash_sb')==='1'){ document.body.classList.add('sb-collapsed'); el('collapse-btn').setAttribute('aria-pressed','true'); } }catch(e){}
  setThemeLabel();
  setPaletteLabel();
  document.addEventListener('click', onClick);
  document.addEventListener('input', onInput);
  // A <select> (enum config knobs) reliably fires change everywhere; input is
  // not guaranteed on every engine. onInput is idempotent, so double-firing on
  // engines that emit both costs nothing.
  document.addEventListener('change', onInput);
  document.addEventListener('scroll', function(e){
    var t=e.target; if(!S.route) return; var ui=uiFor(routeKey(S.route));
    if(t && t.getAttribute){ if(t.hasAttribute('data-listscroll')) ui.listScroll=t.scrollTop; if(t.hasAttribute('data-viewerscroll')) ui.viewerScroll=t.scrollTop; }
  }, true);
  window.addEventListener('scroll', function(){ if(S.route) uiFor(routeKey(S.route)).pageScroll=window.scrollY; }, {passive:true});
  window.addEventListener('popstate', function(){ applyRoute(true); });
  window.addEventListener('resize', function(){ if(S.route && (S.route.name==='term'||S.route.name==='chat')) termFit(); });
  document.addEventListener('visibilitychange', function(){ if(!document.hidden) tick(true); });

  S.route=parseRoute(location.pathname);
  if(S.route.name==='root'){ history.replaceState({}, '', '/fleets'); S.route=parseRoute('/fleets'); }
  if(S.route.name==='config' && !S.cfgSection) S.cfgSection=CFG_SECTIONS[0].id;
  syncViewer(S.route);
  renderNav(); renderHead(); renderPage();
  tick(true);
  setInterval(function(){ tick(false); if(S.route && S.route.name==='search') runSearch(); }, POLL_MS);
}
boot();
</script>
</body>
</html>`;

// "guide" (§4/§8/§9/§12/§13 cited above): the dash-uiux guide is real and
// lives OUTSIDE this repository, at data/external/hermes-dashboard-uiux-guide.md
// under the fleet home - verified by matching every cited section number
// against that document's own headings, not invented.
