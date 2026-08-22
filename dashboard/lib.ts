// lib.ts - the dashboard's PURE layer: parsers, theme tokens, and the board
// joiners. No IO and no imports - both the server (app.ts) and the SPA shell
// (page.ts) depend on it, and PAGE interpolates many of these functions'
// .toString() into the client script, so everything here stays ES5-plain and
// self-contained.

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
 * is surfaced (deliberate - the Reports tree shows all folders/files), so
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
// The 16 ANSI slots, per theme (Warp-style theme/background support).
// A terminal's TEXT colour is chosen by the agent, not by us, so painting only
// the ground is what made a light page unreadable: slots 7 and 15 are what a
// dark-ground TUI uses for ordinary text, and left as near-white they vanish.
// Warp's answer is the one taken here - remap the whole palette per theme - so
// the light set inverts the two ends (7/15 become dark) and darkens every hue
// enough to hold on #f3f5f7, while the dark set is the palette that was already
// hardcoded in ansiToHtml. One source, read by BOTH terminal surfaces: the
// snapshot pane emits var(--ansi-N), and the web terminal is handed the
// resolved values for xterm's own theme object.
export const ANSI_DARK =
  "--ansi-0:#616161; --ansi-1:#ff8272; --ansi-2:#b4fa72; --ansi-3:#fefdc2; --ansi-4:#a5d5fe; --ansi-5:#ff8ffd; --ansi-6:#d0d1fe; --ansi-7:#f1f1f1;\n" +
  "    --ansi-8:#8e8e8e; --ansi-9:#ffc4bd; --ansi-10:#d6fcb9; --ansi-11:#fefdd5; --ansi-12:#c1e3fe; --ansi-13:#ffb1fe; --ansi-14:#e5e6fe; --ansi-15:#feffff;";
export const ANSI_LIGHT =
  "--ansi-0:#24292f; --ansi-1:#cf222e; --ansi-2:#116329; --ansi-3:#9a6700; --ansi-4:#0969da; --ansi-5:#8250df; --ansi-6:#1b7c83; --ansi-7:#4b5563;\n" +
  "    --ansi-8:#57606a; --ansi-9:#a40e26; --ansi-10:#1a7f37; --ansi-11:#7d4e00; --ansi-12:#0550ae; --ansi-13:#6639ba; --ansi-14:#1b6f78; --ansi-15:#1d2530;";
export const THEME_VARS = `
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

// UX baseline (ui-ux-pro-max audit refactor),
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
export const UX_BASE = `
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
export const THEME_INIT = `<script>(function(){try{var t=localStorage.getItem('ac_dash_theme');if(t==='light'||t==='dark')document.documentElement.setAttribute('data-theme',t);var p=localStorage.getItem('ac_dash_palette');if(p==='teal'||p==='navy')document.documentElement.setAttribute('data-palette',p);var st=document.documentElement.style;var c=localStorage.getItem('ac_dash_bg');if(c&&/^#([0-9a-f]{3}|[0-9a-f]{6})$/.test(c.trim().toLowerCase()))st.setProperty('--canvas',c.trim());var im=localStorage.getItem('ac_dash_bg_img');if(im&&im.slice(0,11)==='data:image/'){var dr=localStorage.getItem('ac_dash_bg_dim');var d=(dr==null||dr==='')?55:Number(dr);if(!isFinite(d))d=55;d=Math.min(95,Math.max(0,Math.round(d)));st.setProperty('--bg-img','url("'+im+'")');st.setProperty('--bg-img-op',String((100-d)/100));}}catch(e){}})();</script>`;

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
  return `${self}{ font-size:15px; line-height:1.6; max-width:82ch; }
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
  domain: string; // crewdomain token at its grammar position, "" if none
}

/**
 * Parse ONE backlog line into the fields the board card + detail render (§9
 * grammar). Pure regex over the SAME raw string parseBacklog keeps - the fields
 * live inside that string and are never stored broken out.
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
  // The crewdomain assignment token, position-pinned exactly like the awk
  // twin (AC_DONELINE_AWK f["domain"]): before a trailing (repo: ...) group,
  // or at end of line. Never anywhere-matched - a prose mention is inert.
  const dm = s.match(/; domain:([a-z0-9-]+) \(repo: [^()]*\)$/) || s.match(/; domain:([a-z0-9-]+)$/);
  const domain = dm ? dm[1] : "";
  return { id, text, repo, pr, merged, epic, domain, isEpic: /\[EPIC/i.test(s), contract };
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
    // tasks/<slug>/... are fan-out SUB-TASKS, not stages - they render in the
    // overview's own Sub-tasks panel (composeFamily.subtasks), never as a
    // phantom "tasks" stage whose report is whichever sub-task's came last.
    if (parts[0] === "tasks" && parts.length >= 2) continue;
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
  subtasks: FamilySubtask[]; // section-8 fan-out units - derived, never minted
}

/** One intra-family fan-out unit (`<family>-<slug>`: fan-out crewmate, QA
 *  round, revision) - NOT a ledger story. Derived from task metas (live +
 *  archived) joined with the data dirs' artifacts. */
export interface FamilySubtask {
  id: string;
  slug: string; // id minus the family prefix, what the captain scans
  repo: string;
  pr: string;
  prMerged: boolean;
  live: boolean; // a live state/<id>.meta exists (still flying)
  hasReport: boolean; // the unit's report.md exists - the done artifact
  reportId: string; // the report's artifact id (flat or tasks/-nested path), "" if none
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
  tasks?: { id: string; family: string; repo: string; pr: string; prMerged: boolean; kind?: string; live?: boolean }[];
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

  // Sub-tasks (section-8 intra-family fan-out): `<family>-<slug>` units that
  // are NOT ledger stories - derived from task metas (live + archived) joined
  // with the data dirs' artifacts, never minted. The artifact join is what
  // keeps a fan-out whose meta was pruned visible through its report dir.
  const storyIds: string[] = (input.children || []).map((c) => c.id);
  const storySet: { [id: string]: 1 } = {};
  for (const s of storyIds) storySet[s] = 1;
  // A unit extending a STORY id belongs to that story's own panel, never the
  // epic's (measured: 91 of a live epic's 105 candidates were story-owned);
  // any -chief id is a chief, not a sub-task, whoever it belongs to.
  const subOf = (id: string) =>
    id !== input.family && id.indexOf(input.family + "-") === 0 &&
    !storySet[id] && !/-chief$/.test(id) &&
    !storyIds.some((s) => id.indexOf(s + "-") === 0);
  const subMap: { [id: string]: FamilySubtask } = {};
  const subAt = (id: string): FamilySubtask =>
    subMap[id] || (subMap[id] = { id, slug: id.slice(input.family.length + 1), repo: "", pr: "", prMerged: false, live: false, hasReport: false, reportId: "" });
  for (const t of tasks) {
    if (!subOf(t.id) || /^(roomchief|verify)/.test(t.kind || "")) continue;
    const e = subAt(t.id);
    e.repo = realRepo(t.repo);
    e.pr = t.pr || "";
    e.prMerged = !!t.prMerged;
    e.live = !!t.live;
  }
  for (const a of input.artifacts || []) {
    // tasks/-nested layout: the unit lives INSIDE the family dir, so its
    // artifacts carry the family itself plus a tasks/<slug>/ stage path -
    // the id (<family>-<slug>) matches the meta id, so the two sources merge.
    const nested = a.family === input.family && /^tasks\/([^/]+)\//.exec(a.stage || "");
    const subId = nested ? input.family + "-" + nested[1] : (subOf(a.family) ? a.family : "");
    if (!subId) continue;
    const e = subAt(subId);
    if (/(^|\/)report\.md$/.test(a.id)) { e.hasReport = true; e.reportId = a.id; }
  }
  const subtasks = Object.keys(subMap).sort().map((k) => subMap[k]);

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
    subtasks,
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

/**
 * Chief-panel pane auto-fit: the font size that makes `cols` monospace
 * columns span the pane's available pixel width. Ceiling 15px (chosen from
 * a measured 151-col pane at a 1399px panel):
 * filling the panel outranks matching the native web terminal's own font
 * size, bounded so a narrow-true-width pane still isn't magnified into
 * ugliness. Floor 9.5px keeps a very-wide pane legible instead of vanishing.
 * `0.6` is JetBrains Mono's measured advance-width ratio in Chrome (the
 * stack's lead font since the WezTerm-parity order);
 * `26` is the .cterm horizontal padding (12px * 2) plus a small rounding
 * margin. Pure math - PAGE interpolates its toString(), the bun test proves
 * the same formula the browser runs.
 */
export function chiefFitPx(cols: number, clientWidth: number): number {
  return Math.max(9.5, Math.min(15, (clientWidth - 26) / (cols * 0.6)));
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
/** Reports-tree stem grouping: a top-level folder named `<base>-<suffix>` whose
 *  `<base>` is itself a present top-level folder is a section-8 fan-out
 *  sub-family - regroup it under the base (chains follow transitively:
 *  base -> -e34 -> -r2) so one family's fan-outs, QA rounds and revisions read
 *  as one group instead of N siblings. Only the GROUPING id (gid) is written;
 *  a.id and navigation stay untouched. ES5-plain: PAGE interpolates. */
export function stemRegroup(list: { id: string }[]): { id: string; gid?: string }[] {
  var tops: { [k: string]: 1 } = {};
  for (var i = 0; i < list.length; i++) {
    var t = String(list[i].id || "").split("/")[0];
    if (t) tops[t] = 1;
  }
  var memo: { [k: string]: string } = {};
  var gidOf = function (fam: string): string {
    if (memo[fam] !== undefined) return memo[fam];
    memo[fam] = fam; // self while resolving, so a pathological cycle terminates
    for (var cut = fam.lastIndexOf("-"); cut > 0; cut = fam.lastIndexOf("-", cut - 1)) {
      var p = fam.slice(0, cut);
      if (tops[p] === 1) { memo[fam] = gidOf(p) + "/-" + fam.slice(cut + 1); break; } // longest present prefix wins
    }
    return memo[fam];
  };
  var out = [];
  for (var j = 0; j < list.length; j++) {
    var a: any = list[j];
    var seg = String(a.id || "").split("/");
    var g = gidOf(seg[0]);
    if (g === seg[0]) { out.push(a); continue; }
    var copy: any = {};
    for (var k in a) copy[k] = a[k];
    copy.gid = [g].concat(seg.slice(1)).join("/");
    out.push(copy);
  }
  return out;
}

export function groupArtifacts(list: { id: string; gid?: string; mtime: number }[]): ArtifactNode {
  var root: ArtifactNode = { name: "", key: "", dirs: [], files: [], mtime: 0, count: 0 };
  for (var i = 0; i < list.length; i++) {
    var a = list[i];
    var raw = String(a && (a.gid != null ? a.gid : a.id) != null ? (a.gid != null ? a.gid : a.id) : "").split("/");
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
  s = s.replace(/\`([^\`]+)\`/g, (_m, c) => keep("<code>" + c + "</code>"));
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

/** Mermaid render pass for a markdown reader, shared verbatim (toString()) by
 * /review's iframe overlay AND the SPA's markdown readers (Reports, Records,
 * Board) - reports-mermaid: the SPA readers used to leave a ```mermaid fence
 * as escaped source text, and the review iframe had its own copy of this same
 * pass. ONE implementation now, not two: renders the SVG INSIDE the existing
 * element (a fence's <pre>, or a self-mermaid pre/div) so anything else
 * already riding on it - a review pin anchor, renderMarkdown's data-srcline -
 * moves with it for free, never needing to be copied onto a replacement node.
 * class=mermaid blocks get the same treatment ONLY when the artifact ships no
 * mermaid of its own (foreign-script sniff below; data-acrv marks the review
 * overlay's own <script> so it never counts as foreign) - a self-rendering
 * HTML artifact keeps its own theme/config. renderMarkdown never emits
 * pre.mermaid/div.mermaid, so `blocks` is always empty for the SPA readers;
 * the sniff itself may false-trigger there too (the SPA's own bundle mentions
 * "mermaid" many times, including in this very function's injected source),
 * which is harmless since it can only ever suppress an always-empty set.
 * data-mmd claims an element before its render starts and data-processed
 * marks it done, so a second call over the same DOM (a poll re-render, a
 * fresh boot()) is a query pass that touches nothing already rendered - and
 * costs nothing on markdown with no fences (the early return below, before
 * any CDN load). Never rejects, so a CDN failure still resolves and never
 * blocks a caller awaiting it (dash-review-polish-scroll r1: the review
 * overlay's boot() awaits this before signaling ready).
 * `loadMermaid` stays a parameter rather than a literal import() of the CDN
 * URL here - the same DI mermaidImportWithFallback above already uses for its
 * `parse` callback - so this shared function needs no live module resolution
 * of its own; each interpolation site (the review iframe's <script>, the
 * SPA's page script) owns its own CDN specifier as plain text, same as today.
 * `theme`/`paperStyle` are ALSO parameters, not hardcoded, for the same
 * readerCss-precedent reason (scope is a parameter, the rules are not): the
 * review iframe's diagrams sit on a hardcoded white card regardless of the
 * dashboard's own theme (matching the auto-embedded whiteboard cards' own
 * white paper, review-page-missing-markdown-table-css), while the SPA's own
 * readers (Reports/Records/Board) want the diagram to follow the dashboard's
 * live theme - `mm.render`'s theme and the paper background it sits on are
 * coupled (a light-theme SVG's dark text is illegible on a dark paper), so
 * both travel together as one pair a caller supplies, never guessed here. */
export function mermaidPass(loadMermaid: () => Promise<any>, theme: string, paperStyle: string): Promise<void> {
  const fences = document.querySelectorAll("pre > code[class*=language-mermaid]");
  const foreign = Array.prototype.some.call(document.querySelectorAll("script"), (s: any) =>
    !s.hasAttribute("data-acrv") && ((s.src || "").indexOf("mermaid") >= 0 || (s.textContent || "").indexOf("mermaid") >= 0));
  const blocks = foreign ? [] : Array.prototype.filter.call(
    document.querySelectorAll("pre.mermaid, div.mermaid"),
    (el: Element) => !el.querySelector("svg") && !el.getAttribute("data-processed"));
  if (!fences.length && !blocks.length) return Promise.resolve();
  return loadMermaid().then((mm: any) => {
    mm.initialize({ startOnLoad: false, theme });
    const draw = (el: Element, src: string, i: number) => {
      if (el.getAttribute("data-mmd")) return Promise.resolve();
      el.setAttribute("data-mmd", "1");
      return mm.render("rvmmd" + i, src).then((r: any) => {
        el.innerHTML = r.svg;
        el.setAttribute("data-processed", "true");
        (el as HTMLElement).style.cssText = paperStyle;
      }).catch(() => { el.setAttribute("data-mmd", "err"); });
    };
    const draws: Promise<void>[] = [];
    fences.forEach((code, i) => { const pre = code.closest("pre"); if (pre) draws.push(draw(pre, code.textContent || "", i)); });
    blocks.forEach((el: Element, i: number) => draws.push(draw(el, el.textContent || "", fences.length + i)));
    return Promise.all(draws).then(() => undefined);
  }).catch(() => undefined);
}


/** Paint-guard predicate (dash-review-polish-paint): true iff the frame
 * rendered something the captain can actually see, not merely non-empty
 * bytes. innerText already excludes display:none/visibility:hidden text -
 * the exact false-positive class this guard exists to catch - so a length
 * check on it alone is enough for prose artifacts, AND for a mermaid
 * diagram (verified live, roomchief r1: a settled diagram's own rendered
 * SVG <text> node labels feed innerText, and the review page's own
 * tagDiagrams() wraps every .mermaid/pre.mermaid block in a whiteboard
 * card - "Queue feedback"/"Fullscreen"/"Click to edit" - real visible text
 * present before mermaid even runs; either alone already makes this check
 * true for a real mermaid page, no fallback needed). The img/svg/canvas/
 * video fallback below is for the case innerText genuinely CANNOT catch: a
 * text-free graphic artifact - a markdown/HTML report that is just an
 * embedded image with no caption, or a hand-authored SVG icon with no
 * <text> node (verified live with an img-only fixture: empty innerText,
 * this fallback the only thing that trips true). A body-level
 * background-image check was tried and dropped (roomchief r1): no artifact
 * on disk in this fleet paints solely through one, and it trades a loud
 * false-positive (visible, self-correcting - the captain sees the
 * contradiction) for a silent false-negative (a genuinely blank page
 * carrying any body background-image gets no banner - the exact bug this
 * guard exists to kill, restored). Two checks only, both driven by real
 * elements the artifact itself puts on screen. */
export function artifactPainted(root: Document): boolean {
  const body = root.body;
  if (!body) return false;
  if ((body.innerText || "").trim().length > 0) return true;
  return Array.prototype.some.call(body.querySelectorAll("img, svg, canvas, video"), (el: Element) => {
    const r = el.getBoundingClientRect();
    return r.width > 4 && r.height > 4;
  });
}

/** HTML-escape text (matches the page's client-side esc()). */
export function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

/** Totals for a unified diff - the Source Control section badges. Same
 * line-walk discipline as diffHtml (meta lines never count), self-contained
 * ES5 so PAGE interpolates its toString() beside it. */
export function diffStats(text: string): { add: number; del: number; files: number } {
  var lines = String(text || "").split("\n");
  var add = 0, del = 0, files = 0;
  for (var i = 0; i < lines.length; i++) {
    var l = lines[i];
    if (l.indexOf("diff --git ") === 0) { files++; continue; }
    if (l.indexOf("+++") === 0 || l.indexOf("---") === 0) continue;
    if (l.charAt(0) === "+") add++;
    else if (l.charAt(0) === "-") del++;
  }
  return { add: add, del: del, files: files };
}

/** Unified-diff renderer for the board viewer (worktree diff-review),
 * GitHub-shaped: one collapsible <details class="df"> per file with colored
 * +/- counts and a state badge (added/deleted/renamed/binary), the body a
 * table whose rows carry the old/new line-number gutter pair tracked from the
 * hunk headers; git meta lines (index/---/+++/mode) never render - the file
 * header already says it. Self-contained ES5 (own escaping, no helpers) -
 * PAGE interpolates its toString(), so the browser runs this exact code. */
export function diffHtml(text: string, closed?: boolean): string {
  var src = String(text || "");
  if (!src.replace(/\s/g, "")) return "";
  var lines = src.split("\n");
  var files: { name: string; rows: string[]; add: number; del: number; badge: string }[] = [];
  var cur: { name: string; rows: string[]; add: number; del: number; badge: string } | null = null;
  var oldN = 0, newN = 0;
  function escd(s: string): string {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }
  for (var i = 0; i < lines.length; i++) {
    var l = lines[i];
    if (i === lines.length - 1 && l === "") break;   // the trailing newline's empty tail is not a context line
    if (l.indexOf("diff --git ") === 0) {
      // The b/ side names the file after the change (renames, new files).
      var m = /\sb\/(.+)$/.exec(l);
      cur = { name: m ? m[1] : l.slice(11), rows: [], add: 0, del: 0, badge: "" };
      files.push(cur);
      continue;
    }
    if (!cur) { cur = { name: "(diff)", rows: [], add: 0, del: 0, badge: "" }; files.push(cur); }
    if (l.indexOf("new file") === 0) { cur.badge = "added"; continue; }
    if (l.indexOf("deleted file") === 0) { cur.badge = "deleted"; continue; }
    if (l.indexOf("rename from") === 0 || l.indexOf("rename to") === 0 || l.indexOf("similarity ") === 0) { cur.badge = "renamed"; continue; }
    if (l.indexOf("Binary files") === 0) { if (!cur.badge) cur.badge = "binary"; continue; }
    if (l.indexOf("index ") === 0 || l.indexOf("+++") === 0 || l.indexOf("---") === 0
      || l.indexOf("old mode") === 0 || l.indexOf("new mode") === 0
      || l.indexOf("\\ No newline") === 0) continue;
    var hm = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(l);
    if (hm) {
      oldN = Number(hm[1]); newN = Number(hm[2]);
      cur.rows.push('<tr class="hunk"><td class="ln" colspan="2">&#8943;</td><td class="dc">' + escd(l) + "</td></tr>");
      continue;
    }
    var c0 = l.charAt(0);
    if (c0 === "+") {
      cur.add++;
      cur.rows.push('<tr class="add"><td class="ln"></td><td class="ln">' + newN + '</td><td class="dc">' + escd(l) + "</td></tr>");
      newN++;
    } else if (c0 === "-") {
      cur.del++;
      cur.rows.push('<tr class="del"><td class="ln">' + oldN + '</td><td class="ln"></td><td class="dc">' + escd(l) + "</td></tr>");
      oldN++;
    } else {
      cur.rows.push('<tr class="ctx"><td class="ln">' + oldN + '</td><td class="ln">' + newN + '</td><td class="dc">' + (escd(l) || " ") + "</td></tr>");
      oldN++; newN++;
    }
  }
  var out = "";
  for (var f = 0; f < files.length; f++) {
    var fl = files[f];
    // SCM-panel file row: basename first, its directory de-emphasized after.
    var cut = fl.name.lastIndexOf("/");
    var bn = cut >= 0 ? fl.name.slice(cut + 1) : fl.name;
    var dir = cut >= 0 ? fl.name.slice(0, cut) : "";
    out += '<details class="df"' + (closed ? "" : " open") + '><summary><span class="fn">' + escd(bn) + "</span>"
      + (dir ? ' <span class="fp">' + escd(dir) + "</span>" : "")
      + (fl.badge ? ' <span class="fb ' + fl.badge + '">' + fl.badge + "</span>" : "")
      + ' <span class="n na">+' + fl.add + '</span> <span class="n nd">-' + fl.del + "</span></summary>"
      + '<div class="dfx"><table class="dft"><tbody>' + fl.rows.join("") + "</tbody></table></div></details>";
  }
  return out;
}
