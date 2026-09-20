// page.ts - the SPA shell: one PAGE template literal (inline <style> + inline
// vanilla JS), served for every non-/api GET by app.ts. It interpolates the
// pure layer only - lib.ts functions ride in as .toString() so the browser
// runs the same bun-tested code.
import {
  THEME_INIT, THEME_VARS, UX_BASE,
  boardSystemPanes, cadenceLabel, chiefFitPx, composeFamily, contractTokens,
  deriveProgress, familyInbox, familyOfTaskId, familyRepos, familyStages, fleetAttnItems,
  groupArtifacts, isHtmlArtifact, mermaidPass, nextPalette, nextTheme,
  parseBacklogLine, parseTimeline, readerCss, resolvePalette,
  reviewableArtifact, stemRegroup, storyState, termThemeCore, verifyProcessRows,
  diffHtml, diffStats, graphHtml,
} from "./lib.ts";

// ---------------------------------------------------------------------------
// The SPA shell: inline <style> + inline vanilla JS. No framework, no CDN, no
// build, no external asset - the only reachable thing is the localhost bind.
// The client JS avoids template literals AND backslash-bearing regex literals so
// this outer template literal needs no escaping (a `\` before a non-escape char
// would be swallowed by the template literal, so the router parses paths by
// String.split, never by regex).
// ---------------------------------------------------------------------------

export const PAGE = `<!doctype html>
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
  /* Nav drawer trigger + scrim (dash-responsive): hidden at desktop widths,
     shown only under the phone breakpoint below - the sidebar itself stays a
     sticky flex item until then. */
  .navtoggle{ display:none; background:var(--elev); border:1px solid var(--border); border-radius:4px; padding:5px 9px; color:var(--fg); font-size:16px; line-height:1; flex:0 0 auto; }
  .navtoggle:hover{ border-color:var(--border-strong); }
  .navscrim{ display:none; position:fixed; inset:0; background:var(--scrim); z-index:69; }

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
  /* Caret-only variant (roomchief rows: the NAME beside it is its own link
     into the board detail) - full width here would push the name to a second
     line. */
  .rowdisc.co{ width:auto; margin-right:2px; }
  .tbl td.id a{ color:var(--accent); text-decoration:none; }
  .tbl td.id a:hover{ text-decoration:underline; }
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
  /* brain-ui: readable answer + block hit cards */
  .brainans{ background:var(--surface); border:1px solid var(--border); border-radius:8px; padding:12px 14px; margin:10px 0; }
  .brainans .atext{ white-space:pre-wrap; margin-top:6px; line-height:1.55; }
  .brainans .asrc{ display:flex; flex-wrap:wrap; gap:6px; margin-top:10px; }
  .srcchip{ font-family:var(--mono); font-size:11px; border:1px solid var(--border); border-radius:5px; padding:1px 7px;
    max-width:38ch; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .brainhit{ background:var(--surface); border:1px solid var(--border); border-radius:8px; padding:9px 13px; margin:6px 0; }
  .brainhit .bh1{ display:flex; align-items:center; gap:8px; min-width:0; }
  .brainhit .bh1 a{ font-weight:600; white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  .brainhit .bh1 .ts{ flex:0 1 auto; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; color:var(--fg2); }
  .brainhit .bh2{ color:var(--fg2); font-size:12.5px; margin-top:4px; display:-webkit-box; -webkit-line-clamp:3; -webkit-box-orient:vertical; overflow:hidden; }
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
  /* One line, never wrapped - the full name rides the
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

  /* Phone breakpoint (dash-responsive), the same mark the task-detail rules
     below already use: the sidebar's fixed 224px rail is what overflows a
     phone viewport, so it leaves flex flow and becomes a drawer instead. */
  @media (max-width:720px){
    .navtoggle{ display:inline-flex; min-height:40px; min-width:40px; }
    #collapse-btn{ display:none; } /* icon-rail density has no effect once the sidebar is off-canvas by default */
    /* Touch ergonomics (dash-mobile-responsive, measured 13-30px on a 390px
       viewport): interactive rows/controls meet a finger-sized target on the
       one phone breakpoint; desktop density stays untouched. */
    .navitem, .fleetlist a, .pagenav a{ min-height:40px; }
    .attnq-it{ min-height:44px; }
    .chipm.wait, .btoggle, .btn.sm{ min-height:34px; display:inline-flex; align-items:center; }
    .bch .eye{ min-height:34px; min-width:34px; }
    .sidebar{ position:fixed; top:0; left:0; z-index:70; height:100vh;
      transform:translateX(-100%); transition:transform .18s ease; box-shadow:var(--shadow-pop); }
    body.nav-open .sidebar{ transform:translateX(0); }
    body.nav-open .navscrim{ display:block; }
    /* Master-detail pages (Reports/Records/Config): a fixed side column
       leaves no room for the reader/panel at phone width, so stack instead.
       minmax(0,1fr), not 1fr - a bare 1fr still sizes the track to its
       content's min-content width (measured: the chief terminal below hits
       this same trap), which reintroduces the overflow this block exists to
       remove. */
    .md-layout, .cfg-layout{ grid-template-columns:minmax(0,1fr); }
    /* #toolview's left:var(--sb) assumes the sidebar always occupies its
       224px of flex space - once it goes off-canvas above, that gutter is
       just empty space stealing width from the panel (measured: a review
       opened from Reports squeezed into ~166px and word-wrapped per
       character). */
    #toolview{ left:0; }
  }

  /* ---- Board (dashboard-board): kanban by backlog status + task-detail overlay.
     Colors consume ONLY the semantic tokens above - theme-agnostic by design. ---- */
  .board{ display:grid; grid-template-columns:repeat(3,1fr); gap:14px; align-items:start; }
  .board.hidden-done{ grid-template-columns:repeat(2,1fr); }
  @media (max-width:900px){ .board, .board.hidden-done{ grid-template-columns:minmax(0,1fr); } }
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
  /* Waiting-on-captain highlight: the same amber pair the KPI tile speaks. */
  .bcard.wait{ border-color:var(--warning); border-left-color:var(--warning); background:var(--warn-soft); }
  .bcard.wait:hover{ border-color:var(--warning); }
  .chipm.wait{ color:var(--warning); border-color:var(--warning); background:var(--warn-soft); font-weight:700; }
  /* The wait chip doubles as the approve shortcut (opens the dock at the
     family's pane), so it reads as pressable. */
  .chipm.wait{ cursor:pointer; }
  .chipm.ag-working{ color:var(--good); border-color:var(--good); background:var(--good-soft); }
  .chipm.ag-idle{ color:var(--warning); border-color:var(--warning); background:var(--warn-soft); }
  .chipm.ag-blocked{ color:var(--error); border-color:var(--error); font-weight:700; }
  .chipm.ag-done{ color:var(--muted); }
  .chipm.ag-unknown{ color:var(--muted); border-style:dashed; }
  .chipm.inbx{ color:var(--warning); border-color:var(--warning); background:var(--warn-soft); }
  .chipm.inbx.p{ color:var(--error); border-color:var(--error); background:none; font-weight:700; }
  .chipm.wait:hover{ filter:brightness(1.25); }
  .chipm.shared{ color:var(--success); border-color:var(--success); }
  .chipm.g{ background:var(--good-soft); color:var(--good); border-color:transparent; } .chipm.a{ background:var(--accent-soft); color:var(--accent); border-color:transparent; }
  /* Delivery-contract chips: SOLID = pinned on the row (the captain's word),
     HOLLOW (dashed outline) = chief-chosen at intake, shown for the audit. */
  .chipm.cpin{ background:var(--accent-soft); color:var(--accent); border:1px solid var(--accent); font-weight:600; }
  .chipm.cauto{ background:transparent; color:var(--muted); border:1px dashed var(--muted); }
  .badgeb{ display:inline-block; border-radius:20px; padding:0 7px; font-size:10px; font-weight:700; }
  .badgeb.epic{ background:var(--purple-soft); color:var(--purple); } .badgeb.pr{ background:var(--good); color:var(--bg); }
  .badgeb.ebr{ background:var(--accent-soft); color:var(--accent); font-family:var(--mono); }
  .badgeb.ebr.retired{ opacity:.55; text-decoration:line-through; }
  .badgeb.domain{ background:var(--accent-soft); color:var(--accent); font-family:var(--mono); text-transform:none; }
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
  /* A live system pane IS running work - it reads like any in-flight card
     (green edge, real hover), not like dashed machinery. */
  .bcard.sys{ border-left-color:var(--success); }
  .bcard.sys:hover{ border-left-color:var(--success); }
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
  .bdetail .fhead{ display:flex; align-items:center; flex-wrap:wrap; gap:8px 11px; padding:14px 20px; border-bottom:1px solid var(--line); background:var(--panel-2); flex:0 0 auto; }
  /* overflow-wrap, not break-all: a hyphenated family id breaks at its
     hyphens, never mid-word, and only a truly unbreakable run falls back to
     a character break. */
  .bdetail .fhead .did{ font-family:var(--mono); font-weight:700; font-size:17px; letter-spacing:-.01em; color:var(--ink); overflow-wrap:anywhere; min-width:0; }
  .bdetail .fhead .stt{ background:var(--good-soft); color:var(--good); border-radius:6px; font-size:11px; padding:3px 9px; font-weight:600; white-space:nowrap; flex:0 0 auto; }
  .bdetail .fhead .stt.q{ background:var(--warn-soft); color:var(--warn); } .bdetail .fhead .stt.f{ background:var(--accent-soft); color:var(--accent); }
  .bdetail .fhead .stt.err{ background:transparent; color:var(--error); border:1px solid var(--error); } .bdetail .fhead .stt.stale{ background:transparent; color:var(--stale); border:1px solid var(--stale); }
  .bdetail .fhead .x{ margin-left:auto; font-size:18px; color:var(--muted); border:1px solid var(--line); border-radius:9px; width:32px; height:32px; display:flex; align-items:center; justify-content:center; flex:0 0 auto; }
  .bdetail .fhead .x:hover{ background:var(--bg); color:var(--ink); }
  .bdetail .fbody{ flex:1 1 auto; display:grid; grid-template-columns:300px 1fr; min-height:0; }
  .bdetail .fbody.haschief{ grid-template-columns:300px 1fr 6px var(--chiefw, minmax(360px,34%)); }
  .bdetail .fbody.railcut{ grid-template-columns:26px 1fr; }
  .bdetail .fbody.railcut.haschief{ grid-template-columns:26px 1fr 6px var(--chiefw, minmax(360px,34%)); }
  .bdetail .railtg{ float:right; font:600 11px var(--mono); padding:2px 6px; border:1px solid var(--line); border-radius:4px; background:var(--elev); color:var(--muted); cursor:pointer; }
  .bdetail .fbody.railcut .rail{ padding:6px 2px; }
  .bdetail .fbody.railcut .rail > *:not(.railtg){ display:none; }
  @media (max-width:720px){
    .bdetail .fbody, .bdetail .fbody.haschief, .bdetail .fbody.railcut{ grid-template-columns:minmax(0,1fr); }
    .bdetail .rail{ max-height:40%; }
    /* Stacked rail: a collapse-to-26px control is meaningless, and the big
       mono id needs a phone-sized step down. */
    .bdetail .railtg{ display:none; }
    .bdetail .fbody.railcut .rail > *{ display:block; }
    .bdetail .fhead{ padding:10px 12px; gap:6px 8px; }
    .bdetail .fhead .did{ font-size:14.5px; }
  }
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
    font:12px/1.45 'JetBrains Mono', 'Hack Nerd Font Mono', var(--mono); white-space:pre-wrap; word-break:break-word;
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
  .termpage iframe{ width:100%; border:0; border-radius:0; background:var(--term-bg, var(--canvas)); flex:1 1 auto; min-height:0; }
  .termpage{ position:relative; overflow:hidden; display:flex; flex-direction:column; }
  .termbar{ flex:0 0 auto; display:flex; align-items:center; gap:6px; padding:5px 10px;
    border-bottom:1px solid var(--line); background:var(--surface); }
  .tbtitle{ font-size:11px; color:var(--muted); font-weight:700; }
  .tbsp{ flex:1 1 auto; }
  .tbfs{ font-size:11px; color:var(--fg2); min-width:2ch; text-align:center; }
  /* Terminal dock (every route except the Terminal page - tdRouteOk owns
     the rule): split-right / fullscreen-with-header. */
  .termdock{ position:fixed; top:0; right:0; bottom:0; width:var(--tdw,480px); z-index:60; display:flex;
    background:var(--panel); border-left:1px solid var(--line); box-shadow:-6px 0 22px rgba(0,0,0,.18); }
  /* display:flex above outranks the UA's [hidden]{display:none} - without
     this, a "closed" dock stands as an empty shell on EVERY page (captain
     screenshot: blank dock on the Search route). */
  .termdock[hidden]{ display:none; }
  .termdock.full{ width:100vw; border-left:0; }
  .termdock.full .tdgrip{ display:none; }
  .tdgrip{ flex:0 0 6px; cursor:col-resize; background:transparent; }
  .tdgrip:hover{ background:var(--accent-soft); }
  /* Mid-drag: iframes EAT mousemove the instant the pointer crosses them
     (the classic stuck-drag), so they go pointer-inert until mouseup. */
  body.td-dragging iframe{ pointer-events:none; }
  body.td-dragging{ cursor:col-resize; user-select:none; }
  .tdcol{ flex:1 1 auto; min-width:0; display:flex; flex-direction:column; }
  /* Same surface language as the pill: quiet chrome, the pulsing accent dot
     as the live signal; controls are ghost icons that only grow chrome on
     hover, the font pair fused into one segmented control. */
  .tdbar{ flex:0 0 auto; display:flex; align-items:center; gap:8px; padding:7px 12px;
    border-bottom:1px solid var(--line); background:var(--surface); }
  .tddot{ width:7px; height:7px; border-radius:50%; background:var(--accent); flex:0 0 auto;
    animation:tdpulse 1.6s ease-in-out infinite; }
  .tdtitle{ font-size:11.5px; color:var(--muted); display:flex; align-items:baseline; gap:6px; }
  .tdtitle b{ color:var(--accent); font-weight:700; }
  .tdtitle i{ font-style:normal; opacity:.7; }
  .tdsp{ flex:1 1 auto; }
  .tdseg{ display:flex; align-items:center; border:1px solid var(--line); border-radius:6px; overflow:hidden; }
  .tdseg button{ font:600 11px var(--mono); padding:4px 9px; border:0; background:transparent;
    color:var(--muted); cursor:pointer; }
  .tdseg button:hover{ color:var(--ink); background:var(--elev); }
  .tdfs{ font-size:11px; color:var(--fg2); min-width:3ch; text-align:center;
    padding:0 2px; border-left:1px solid var(--line); border-right:1px solid var(--line); align-self:stretch; display:flex; align-items:center; justify-content:center; }
  .tdico{ font:600 12px var(--mono); width:26px; height:24px; display:flex; align-items:center; justify-content:center;
    border:1px solid transparent; border-radius:6px; background:transparent; color:var(--muted); cursor:pointer; }
  .tdico:hover{ color:var(--ink); background:var(--elev); border-color:var(--line); }
  .tdico[aria-pressed="true"]{ color:var(--accent); border-color:var(--accent); }
  #td-close:hover{ color:var(--error); border-color:var(--error); }
  .tdbody{ flex:1 1 auto; min-height:0; position:relative; }
  .tdbody iframe{ width:100%; height:100%; border:0; background:var(--term-bg, var(--canvas)); }
  .tdbody .cdead{ padding:16px; color:var(--muted); }
  /* Connecting overlay: the dock is never a silent blank - this sits over the
     iframe until the frame reports its first pty byte (acTermLive). */
  .tdload{ position:absolute; inset:0; display:flex; align-items:center; justify-content:center;
    color:var(--muted); font:12px var(--mono); background:var(--term-bg, var(--canvas)); pointer-events:none; }
  .tdload span{ animation:tdpulse 1.2s ease-in-out infinite; }
  @keyframes tdpulse{ 0%,100%{ opacity:.35; } 50%{ opacity:1; } }
  body.term-docked .shell{ margin-right:var(--tdw,480px); }
  /* HIDDEN state (chat-widget shape): the dock slides fully off-screen - the iframe STAYS
     MOUNTED so the terminal session survives the hide - and what remains is
     a chat-widget-style floating pill at the bottom-right corner. The pill
     lives OUTSIDE .termdock: a transformed ancestor becomes position:fixed's
     containing block, so a pill inside would slide off with the dock. */
  .termdock.hid{ transform:translateX(100%); box-shadow:none; }
  .termdock.hid .tdgrip{ display:none; }
  .tdrail{ position:fixed; right:18px; bottom:18px; z-index:59; display:flex; align-items:center; gap:7px;
    padding:9px 15px; border-radius:999px; background:var(--panel); border:1px solid var(--line);
    box-shadow:0 4px 16px rgba(0,0,0,.3); cursor:pointer; font:700 12px var(--mono); color:var(--accent); }
  /* Quiet chrome, loud signal: the panel-dark pill keeps the app's surface
     language and the pulsing accent dot is what draws the eye. */
  .tdrail::before{ content:''; width:7px; height:7px; border-radius:50%; background:var(--accent);
    animation:tdpulse 1.6s ease-in-out infinite; }
  .tdrail:hover{ border-color:var(--accent); transform:translateY(-1px); box-shadow:0 6px 20px rgba(0,0,0,.35); }
  .tdrail[hidden]{ display:none; }
  /* Phone (<=720px, the app's one breakpoint): the dock IS the viewport -
     a 480px split on a ~390px screen leaves neither side usable. The grip
     dies with it (nothing to drag), the app never shifts (the dock covers),
     and the desktop width survives untouched in localStorage because the
     override lives here in CSS, not in tdW. */
  @media (max-width:720px){
    .termdock{ width:100vw; border-left:0; }
    .tdgrip{ display:none; }
    body.term-docked .shell{ margin-right:0; }
  }
  /* Pressed state is DELIBERATE accent styling (fullscreen active), never a
     leftover focus ring - clicks blur the button after acting. */
  .termbar .btn[aria-pressed="true"]{ color:var(--accent); border-color:var(--accent); }
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
  .ovstories, .ovsubs{ margin-top:14px; }
  /* Each story is a bordered card row, not a ruled text list. */
  .ovstories .strow, .ovsubs .strow{ display:flex; align-items:center; gap:10px; padding:9px 12px; margin:6px 0;
    background:var(--surface); border:1px solid var(--border); border-radius:8px; color:var(--fg); min-width:0; }
  .ovstories .strow:hover, .ovsubs .strow:hover{ border-color:var(--border-strong); background:var(--elev); text-decoration:none; }
  .ovstories .stid, .ovsubs .stid{ font-family:var(--mono); font-size:11.5px; font-weight:700; color:var(--accent); flex:0 0 auto; max-width:28ch; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .ovstories .srepo, .ovsubs .srepo{ font-family:var(--mono); font-size:9.5px; font-weight:700; color:var(--accent); background:var(--accent-soft);
    border-radius:5px; padding:1px 6px; flex:0 0 auto; max-width:20ch; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
  .ovstories .spr, .ovsubs .spr{ font-family:var(--mono); font-size:9.5px; font-weight:700; color:var(--success); border:1px solid var(--success);
    border-radius:5px; padding:0 6px; flex:0 0 auto; }
  .ovstories .badge, .ovsubs .badge{ flex:0 0 auto; }
  .ovstories .sttx, .ovsubs .sttx{ flex:1 1 auto; min-width:0; display:-webkit-box; -webkit-line-clamp:2; -webkit-box-orient:vertical;
    overflow:hidden; white-space:normal; font-size:12.5px; line-height:1.45; }
  .ovroom .rev{ font-weight:700; font-family:var(--mono); font-size:11px; padding:1px 6px; border-radius:4px; background:var(--elev); }
  .ovroom .rev.warn{ color:var(--warning); border:1px solid var(--warning); }
  .ovroom .rev.ok{ color:var(--success); }
  .ovroom .rev.acc{ color:var(--accent); }
  .chiefp .cbar .cback{ font-size:15px; line-height:1; padding:2px 9px; border:1px solid var(--line); border-radius:4px;
    color:var(--muted); text-decoration:none; }
  .chiefp .cbar .cback:hover{ color:var(--accent); border-color:var(--accent); text-decoration:none; }
  .story .fopen, .tbl .fopen{ margin-left:auto; font-size:11px; padding:1px 7px; border:1px solid var(--line); border-radius:4px; background:var(--elev); color:var(--muted); cursor:pointer; }
  .story .fopen:hover, .tbl .fopen:hover{ color:var(--accent); border-color:var(--accent); }
  .tbl .fopen{ margin-left:6px; }
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
  /* Same weight as .tlbtn: Room, Timeline and the artifact rows are one
     class of action (swap the viewer body) - one visual voice. */
  .bdetail .roombtn{ display:inline-block; margin-top:10px; background:var(--accent-soft); color:var(--accent); border:1px solid var(--line); border-radius:9px; padding:8px 14px; font-size:12.5px; font-weight:600; }
  .bdetail .roombtn:hover{ background:var(--accent); color:var(--accent-ink); text-decoration:none; }
  .bdetail .repotxt{ font-size:12.5px; color:var(--ink); }
  .bdetail .tlbtn{ display:flex; align-items:center; gap:6px; margin-top:10px; width:100%; text-align:left; background:var(--accent-soft); color:var(--accent); border:1px solid var(--line); border-radius:9px; padding:8px 12px; font-size:12.5px; font-weight:600; cursor:pointer; }
  .bdetail .tlbtn:hover{ background:var(--accent); color:var(--accent-ink); }
  .bdetail .tlbtn .n{ color:inherit; opacity:.75; font-weight:400; font-size:11px; }
  /* Worktree diff viewer (diff-review), GitHub-shaped: one collapsible card
     per file, a line-number gutter pair, full-row add/del tints. */
  .df{ border:1px solid var(--line); border-radius:9px; margin:0 0 12px; overflow:hidden; background:var(--surface); }
  /* Code-tree folder nodes wrapping the file cards (view-as-tree). */
  .dfd{ margin:0 0 6px; }
  .dfd>summary{ cursor:pointer; font:600 12px var(--mono); color:var(--fg2); padding:4px 2px; list-style-position:inside; }
  .dfdc{ margin-left:13px; border-left:1px solid var(--line); padding-left:11px; }
  .df>summary{ cursor:pointer; padding:8px 12px; font:600 12.5px/1.4 var(--mono); border-bottom:1px solid var(--line); list-style-position:inside; }
  .df>summary .n{ font-weight:600; font-size:11px; margin-left:2px; }
  .df>summary .na{ color:var(--success); }
  .df>summary .nd{ color:var(--error); }
  .df>summary .fb{ font-size:10px; font-weight:600; text-transform:uppercase; letter-spacing:.04em; padding:1px 6px; border-radius:9px; border:1px solid var(--line); color:var(--muted); margin-left:4px; }
  .df>summary .fb.added{ color:var(--success); border-color:var(--success); }
  .df>summary .fb.deleted{ color:var(--error); border-color:var(--error); }
  .dfx{ overflow-x:auto; }
  .dft{ border-collapse:collapse; width:100%; font:12px/1.6 var(--mono); }
  .dft td{ padding:0 10px; vertical-align:top; }
  .dft .ln{ width:1%; min-width:36px; text-align:right; color:var(--muted); font-size:11px; user-select:none; background:color-mix(in srgb, var(--elev) 55%, transparent); }
  .dft .dc{ white-space:pre; }
  .dft tr.add .dc{ background:color-mix(in srgb, var(--success) 12%, transparent); }
  .dft tr.add .ln{ background:color-mix(in srgb, var(--success) 22%, transparent); }
  .dft tr.del .dc{ background:color-mix(in srgb, var(--error) 12%, transparent); }
  .dft tr.del .ln{ background:color-mix(in srgb, var(--error) 22%, transparent); }
  .dft tr.hunk td{ background:color-mix(in srgb, var(--accent) 10%, transparent); color:var(--accent); padding-top:3px; padding-bottom:3px; }
  .dfnote{ color:var(--warning); font-size:12px; padding:4px 2px; }
  .dflive{ color:var(--muted); font-size:11px; margin:0 0 8px; }
  /* Worktrees tab: one collapsible section per leased pool worktree. */
  .scwrap{ padding:16px 20px; }
  .sctask{ border:1px solid var(--line); border-radius:9px; margin:0 0 14px; background:var(--surface); }
  .sctask>summary{ cursor:pointer; padding:9px 14px; display:flex; align-items:center; gap:10px; list-style-position:inside; }
  .sctask>summary .scid{ font-weight:600; font-size:13px; }
  .sctask>summary .scmeta{ margin-left:auto; font:600 11px var(--mono); display:flex; gap:8px; align-items:center; }
  .sctask>summary .na{ color:var(--success); } .sctask>summary .nd{ color:var(--error); }
  .sctask[open]>summary{ border-bottom:1px solid var(--line); }
  .scbody{ padding:10px 14px; }
  .scbody .df{ background:var(--canvas); margin:0 0 6px; }
  .scgroup{ margin:12px 0 6px; font-size:11px; letter-spacing:.05em; text-transform:uppercase; color:var(--muted); }
  .scgroup:first-child{ margin-top:2px; }
  .scgroup .scgn{ color:var(--fg2); font-weight:600; }
  .scgraph{ margin:12px 0 4px; }
  .scgraph>summary{ cursor:pointer; font-size:11px; letter-spacing:.05em; text-transform:uppercase; color:var(--muted); list-style-position:inside; }
  .scgraph.srepo{ margin:2px 0 14px; }
  .scgbody{ margin-top:6px; }
  .ggsel{ margin:0 0 8px; background:var(--elev); color:var(--fg); border:1px solid var(--line); border-radius:7px; padding:4px 8px; font:12px var(--mono); max-width:340px; }
  .ggselbtn{ cursor:pointer; }
  .ggpick{ position:relative; display:inline-block; }
  .ggpanel{ position:absolute; top:100%; left:0; z-index:40; min-width:300px; max-width:420px; background:var(--panel); border:1px solid var(--line); border-radius:9px; box-shadow:0 10px 28px rgba(0,0,0,.28); padding:8px; }
  .ggsearch{ width:100%; box-sizing:border-box; background:var(--elev); color:var(--fg); border:1px solid var(--line); border-radius:7px; padding:5px 9px; font:12px var(--mono); margin-bottom:6px; }
  .ggopts{ max-height:300px; overflow-y:auto; }
  .ggopt{ padding:5px 9px; border-radius:6px; cursor:pointer; font:12px var(--mono); white-space:nowrap; overflow:hidden; text-overflow:ellipsis; }
  .ggopt:hover{ background:var(--accent-soft); color:var(--accent); }
  .ggopt.crew{ color:var(--success); }
  /* Each repo is one CARD: header (name + pull) over the trees and graph. */
  .screpogrp{ border:1px solid var(--line); border-radius:11px; background:var(--surface); margin:0 0 18px; overflow:hidden; }
  .screpo{ display:flex; align-items:center; gap:10px; padding:10px 16px; font:600 13px var(--mono); color:var(--fg); border-bottom:1px solid var(--line); background:color-mix(in srgb, var(--elev) 55%, transparent); }
  .screpo .srtools{ margin-left:auto; display:flex; align-items:center; gap:8px; }
  .screpob{ padding:12px 16px 6px; }
  .screpob .sctask{ background:var(--canvas); }
  .screpob .scbody .df{ background:var(--surface); }
  .screpob .btn.sm{ margin-right:6px; }
  .gghead{ font:500 10.5px var(--mono); padding:1px 7px; border-radius:9px; border:1px solid var(--accent); color:var(--accent); }
  .gghead.det{ border-color:var(--warning); color:var(--warning); }
  .gg{ margin:8px 0 0; padding:6px 4px; overflow-x:auto; border:1px solid var(--line); border-radius:9px; background:var(--canvas); }
  .ggrow{ display:flex; align-items:center; gap:8px; white-space:nowrap; padding:0 8px; border-radius:6px; cursor:pointer; }
  .ggrow:hover{ background:color-mix(in srgb, var(--accent) 8%, transparent); }
  .ggrow svg{ flex:none; display:block; }
  .ggrow svg line, .ggrow svg path{ stroke-width:2; stroke-linecap:round; }
  .gghash{ font:11.5px var(--mono); color:var(--muted); min-width:60px; }
  .ggref{ font:500 10.5px var(--mono); padding:0 7px; border-radius:8px; border:1px solid var(--accent); color:var(--accent); }
  .ggref.head{ background:var(--accent); color:var(--accent-ink); border-color:var(--accent); }
  .ggref.crew{ border-color:var(--success); color:var(--success); }
  .ggref.base{ border-color:var(--warning); color:var(--warning); }
  .ggmsg{ font-size:12.5px; overflow:hidden; text-overflow:ellipsis; }
  .ggrow.mg .ggmsg, .ggrow.mg .gghash{ color:var(--muted); font-size:11.5px; }
  .gg .glh{ stroke:transparent; stroke-width:11; fill:none; pointer-events:stroke; cursor:pointer; }
  .gg .gl.dim{ opacity:.18; }
  .ggdiff{ padding:4px 8px 10px 34px; cursor:default; }
  .df>summary .fp{ color:var(--muted); font-size:11px; font-weight:400; }
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
  <div id="nav-scrim" class="navscrim"></div>
  <main id="main" class="main">
    <header class="pagehead">
      <button id="nav-toggle" class="navtoggle" type="button" aria-label="Open navigation" aria-controls="sidebar" aria-expanded="false">&#9776;</button>
      <div class="headline">
        <h1 id="page-title">Fleets</h1>
        <div id="page-crumb" class="crumb"></div>
        <div id="page-meta" class="meta"></div>
      </div>
      <div class="actions">
        <span id="live" class="live" role="status" aria-live="polite"><span class="dot" aria-hidden="true"></span><span id="live-text">connecting&hellip;</span></span>
        <button id="theme-btn" class="btn sm" type="button" aria-label="Cycle theme: auto, light, dark" title="Cycle theme: auto, light, dark">&#127765;</button>
        <button id="refresh-btn" class="btn sm" type="button">&#8635; Refresh</button>
      </div>
    </header>
    <div id="page" class="page" tabindex="-1" aria-live="polite">
      <div class="skeleton"><div class="sk"></div><div class="sk"></div><div class="sk"></div></div>
    </div>
  </main>
</div>
<!-- Terminal dock (every route except
     the Terminal page, whose own full client made the v2 global dock lag
     with two clients at once - tdRouteOk owns the rule). Lives OUTSIDE #page
     so route morphs never remount the iframe; only entering the Terminal
     page closes the dock and ends its session. Fullscreen KEEPS this header
     (v1's one real defect: header covered, controls lost). -->
<div id="term-dock" class="termdock" hidden>
  <div class="tdgrip" id="td-grip" title="Drag to resize (min 320px, max 72% of the window)"></div>
  <div class="tdcol">
    <div class="tdbar">
      <span class="tddot" aria-hidden="true"></span>
      <span class="tdtitle mono"><b>herdr</b><i>dock</i></span>
      <span class="tdsp"></span>
      <span class="tdseg" role="group" aria-label="Terminal font size">
        <button type="button" id="td-fminus" title="Smaller terminal font">A-</button>
        <span id="td-fsize" class="tdfs mono">12</span>
        <button type="button" id="td-fplus" title="Larger terminal font">A+</button>
      </span>
      <button type="button" class="tdico" id="td-min" title="Hide to the edge - the session keeps running">&#8677;</button>
      <button type="button" class="tdico" id="td-full" aria-pressed="false" title="Fullscreen (header stays; press again or Esc outside the terminal to return to split)">&#x2922;</button>
      <button type="button" class="tdico" id="td-close" title="Close the dock - the terminal session ends (Ctrl+&#96; reopens)">&#10005;</button>
    </div>
    <div class="tdbody" id="td-body"></div>
  </div>
</div>
<button type="button" class="tdrail" id="td-rail" title="Show the terminal dock" hidden>&gt;_ herdr</button>
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
${stemRegroup.toString()}
${isHtmlArtifact.toString()}
${reviewableArtifact.toString()}
${cadenceLabel.toString()}
${fleetAttnItems.toString()}
${familyInbox.toString()}
${verifyProcessRows.toString()}
${chiefFitPx.toString()}
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
${diffHtml.toString()}
${diffStats.toString()}
${graphHtml.toString()}
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
         (h.watcher && h.watcher.state!=='armed' && supervisedCrew(h)>0) ||
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
    if(pg==='worktrees' && parts.length===3) return { name:'worktrees', fleet:fleet };
    if(pg==='changes' && parts.length===3) return { name:'worktrees', fleet:fleet };   // pre-rename deep links stay alive (the backlog->board precedent)
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
  toggleNav(false); // a route change is the drawer's other close trigger, on top of the scrim/hamburger
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
  // The chat route is retired - old links land on the board with the dock up
  // (the dock is where chat lives now).
  if(r.name==='chat' && r.fleet){
    navigate('/fleets/'+enc(r.fleet)+'/board', {replace:true});
    if(typeof tdOpen==='function' && tdMode==='closed') tdOpen('split');
    return;
  }
  if(r.fleet){ r.home=fleetByName(S.snap, r.fleet); rememberFleet(r.fleet); }
  var changed = !prev || prev.name!==r.name || prev.fleet!==r.fleet;
  if(changed){ pollGen++; if(pageCtrl){ try{pageCtrl.abort();}catch(e){} } pageInFlight=false; S.page=null; S.pageFail=false; toolClose(); }
  S.route=r;
  // Leaving the dock-carrying screens closes the dock and ends its session -
  // this is what keeps it structurally unable to coexist with the /terminal
  // page's own client (the v2 two-clients lag).
  if(typeof tdMode!=='undefined' && tdMode!=='closed' && !tdRouteOk()) tdClose(false);
  // The standing intent reopens the dock on every carrying route - boot after
  // a reload included - so the terminal is ALWAYS loaded once the captain
  // opened it, until their own X says otherwise.
  if(typeof tdMode!=='undefined' && tdMode==='closed' && tdIntent && tdRouteOk()) tdOpen(tdIntent);
  if(typeof tdApply==='function') tdApply(); // pill visibility follows the route
  // (Answering happens IN PLACE on the amber card/detail - the dock never
  // auto-moves; superseded the short-lived auto-aim.)
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
  if(r.name==='worktrees') return '/api/processes?path='+p;   // the pool list IS this page's data
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
// crew.supervised is crew.count minus the kind=self metas (bin/ac-fleets.sh:
// a self task is LISTED and owes no watcher coverage). An older cached snapshot
// carries no such key and falls back to count, exactly as this page read it.
function supervisedCrew(h){
  if(!h.crew) return 0;
  return (h.crew.supervised==null) ? (h.crew.count||0) : h.crew.supervised;
}
function statusDot(h){
  if(h.watcher && h.watcher.state!=='armed' && supervisedCrew(h)>0) return 'err';
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
    ['Monitor', [['board','Board'],['processes','Processes'],['worktrees','Worktrees']]],
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
  var titles={fleets:'Fleets', processes:'Processes', worktrees:'Worktrees', board:'Board', chat:'Chat', term:'Terminal', brain:'Brain', reports:'Reports', reviews:'Reviews', whiteboards:'Whiteboards', records:'Records', domains:'Domains', learning:'Learning', search:'Search', config:'Config', notfound:'Not found', root:'Fleets'};
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
  if(r.name==='worktrees' && S.page && S.page.pools){ var cp=S.page.pools, cn=0;
    for(var ci=0;ci<cp.length;ci++){ if(cp[ci].state==='leased') cn++; }
    return '<span>'+cn+' leased worktree'+(cn===1?'':'s')+'</span>'; }
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
  else if(r.name==='worktrees') html=pageWorktrees();
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
  if(r && r.name==='term'){ termTheme(); termFontLabel(); }   // frame not up yet on the first pass - the next render lands it
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
  // Opens the dock IN PLACE - never a route hop; the dock is where chat lives.
  s+='<button type="button" class="chip" style="margin-left:auto" data-td-open data-td-fleet title="Watch and message this fleet\u2019s crewchief session in the terminal dock">\uD83D\uDCAC Crewchief</button>';
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
    // A roomchief's NAME goes to its family's board detail; the caret alone
    // keeps the inline expand. Other expandable rows keep name+caret as one
    // expander.
    var famHref=(row.work==='roomchief'&&/-chief$/.test(row.id))
      ? '/fleets/'+enc(S.route.fleet)+'/board/'+enc(row.id.replace(/-chief$/,'')) : null;
    if(expandable && famHref){
      s+='<button class="rowdisc co" data-exprow="'+esc(rid)+'" aria-expanded="'+(open?'true':'false')+'" title="Expand"><span class="caret">'+(open?'&#9662;':'&#9656;')+'</span></button>'
        +'<a href="'+famHref+'" data-link title="Open this family&#39;s board detail">'+esc(row.id)+'</a>';
    }
    else if(expandable){ s+='<button class="rowdisc" data-exprow="'+esc(rid)+'" aria-expanded="'+(open?'true':'false')+'"><span class="caret">'+(open?'&#9662;':'&#9656;')+'</span>'+esc(row.id)+'</button>'; }
    else { s+=esc(row.id); }
    s+='</td>';
    s+='<td class="mono">'+esc(row.work)
      +(famHref?' <button type="button" class="fopen" data-td-open data-td-family="'+esc(row.id.replace(/-chief$/,''))+'" title="Open the dock at this roomchief&#39;s pane">💬</button>':'')
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

  // Token usage (dash-usage-panel): raw token sums per LIVE task, straight
  // from each session's transcript. Main-session file only - a crewmate's
  // subagent spend is not attributed (the note says so; no silent caps).
  var us=(S.page&&S.page.usage)||[];
  s+='<h2 style="font-size:14px;margin:18px 0 8px;color:var(--fg2)">Token usage <span class="muted" style="font-weight:400;font-size:11px">live tasks &middot; main session only &middot; raw tokens, no $ estimate</span></h2>';
  if(!us.length){ s+='<div class="muted">no live task transcripts</div>'; }
  else{
    var tt={inp:0,out:0,cr:0,cw:0}, td={inp:0,out:0,cr:0,cw:0};
    var ur='';
    for(var uu=0;uu<us.length;uu++){ var u1=us[uu];
      tt.inp+=u1.total.inp; tt.out+=u1.total.out; tt.cr+=u1.total.cr; tt.cw+=u1.total.cw;
      td.inp+=u1.today.inp; td.out+=u1.today.out; td.cr+=u1.today.cr; td.cw+=u1.today.cw;
      ur+='<tr><td class="mono">'+esc(u1.id)+'</td><td class="mono" style="font-size:11px">'+esc((u1.models||[]).join(', ')||'—')+'</td>'
        +'<td class="mono">'+fmtTok(u1.today.out)+'</td>'
        +'<td class="mono">'+fmtTok(u1.total.out)+'</td><td class="mono">'+fmtTok(u1.total.inp)+'</td><td class="mono">'+fmtTok(u1.total.cr)+'</td></tr>';
    }
    ur+='<tr style="font-weight:700"><td>total</td><td></td><td class="mono">'+fmtTok(td.out)+'</td><td class="mono">'+fmtTok(tt.out)+'</td><td class="mono">'+fmtTok(tt.inp)+'</td><td class="mono">'+fmtTok(tt.cr)+'</td></tr>';
    s+='<div class="tblwrap"><table class="tbl"><thead><tr><th>Task</th><th>Model</th><th>Out today</th><th>Out total</th><th>In total</th><th>Cache read</th></tr></thead><tbody>'+ur+'</tbody></table></div>';
  }
  return s;
}
// Humanized token count: 1234 -> 1.2k, 5300000 -> 5.3M (raw below 1000).
function fmtTok(n){
  n=n||0;
  if(n>=1000000) return (n/1000000).toFixed(1)+'M';
  if(n>=1000) return (n/1000).toFixed(1)+'k';
  return String(n);
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
    var rooms=(j&&j.rooms)||[], n=0, fams=[];
    for(var i=0;i<rooms.length;i++){ if(rooms[i].pending||rooms[i].handback){ n++; fams.push(rooms[i].family); } }
    boardKpiC[hp]={ ts:Date.now(), pending:n, fams:fams, loading:false };
    if(S.route && S.route.name==='board') renderPage();
  }).catch(function(){ boardKpiC[hp]={ ts:Date.now(), pending:(c&&c.pending), fams:(c&&c.fams), loading:false }; });
}
// A family WAITING ON THE CAPTAIN is highlighted in place, in the same amber
// language as the awaiting-captain KPI tile: an open GATE/ASK/handback in its
// room (the KPI's own source), or a captain-held row. The held check is
// display-only (the scheduler's strict grammar stays in ac-ready) and matches
// the token PREFIX so the dated arm [@held until YYYY-MM-DD] highlights too.
function boardWaits(fam, line){
  if(line && line.indexOf('[@held')>=0 && line.indexOf(String.fromCharCode(96)+'[@held')<0) return true;
  var hp=S.route&&S.route.home?S.route.home.path:'';
  var c=hp&&boardKpiC[hp];
  return !!(c&&c.fams&&c.fams.indexOf(fam)>=0);
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
// family -> live agent state (dash-agent-status-chips): herdr's own 5-state
// detection per task id, folded per family WORST-FIRST - a family with one
// blocked pane reads blocked, whatever its siblings do. Absent = no chip.
var AG_RANK={blocked:0, idle:1, working:2, unknown:3, done:4};
function famAgentStates(agents, known){
  var map={};
  for(var id in agents){ if(!Object.prototype.hasOwnProperty.call(agents,id)) continue;
    var fam=familyOfTaskId(id, known), st=agents[id], cur=map[fam];
    if(cur===undefined || (AG_RANK[st]||9)<(AG_RANK[cur]||9)) map[fam]=st;
  }
  return map;
}
function agentChip(st){
  if(!st) return '';
  return '<span class="chipm ag-'+esc(st)+'" title="live agent state (herdr agent detection)">'+esc(st)+'</span> ';
}
// Room-inbox badge (dash-family-inbox): the same pending/handback truth the
// fleets-overview attention queue shows, on the family's own card. The badge
// title carries the room's last entry so hover answers "waiting on WHAT".
function inboxChips(it){
  if(!it) return '';
  var s='';
  if(it.pending>0) s+=' <span class="chipm inbx p" title="'+esc(it.last||'')+'">⚑ '+it.pending+' gate/ask</span>';
  if(it.handback) s+=' <span class="chipm inbx" title="'+esc(it.last||'')+'">HANDBACK</span>';
  return s;
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
// The delivery-contract chip row (dashboard shows the MODES a task runs).
// SOLID chip (.cpin) = a token pinned on the row,
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

// A family's detail IN the page (board-style, no route hop), not a
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
  var agents=(S.page&&S.page.agents)||{};
  var agFam=famAgentStates(agents, bd.known);
  var inbox=familyInbox(r.home&&r.home.inbox?r.home.inbox.entries:[]);
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
      shown++; cards+=boardCard(f, lines[i], key, arts, bd, live[f.id], liveModes[f.id], agFam[f.id], inbox[f.id]);
    }
    if(key==='in_flight'){ for(var sp=0;sp<sysPanes.length;sp++){ var pn=sysPanes[sp];
      if(q && (pn.id+' '+pn.kind+' '+pn.status).toLowerCase().indexOf(q)<0) continue;
      var pfam=(pn.kind==='roomchief' && /-chief$/.test(pn.id)) ? pn.id.replace(/-chief$/,'') : pn.id;
      shown++; cards+=boardSysCard(pn, agents[pn.id], inbox[pfam]); } }
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
function boardCard(f, line, sectionKey, arts, bd, liveStatus, liveMode, agState, inboxIt){
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
  var domBadge=f.domain?' <span class="badgeb domain" title="crewdomain '+esc(f.domain)+' - start = promote its domainchief">'+esc(f.domain)+'</span>':'';
  var badges=(d.isEpic?' <span class="badgeb epic">EPIC</span>':'')+domBadge+(d.pr?' <span class="badgeb pr">PR</span>':'')+termBadge;
  var chips=''; for(var i=0;i<d.stages.length;i++){ var st=d.stages[i]; chips+='<span class="chipm '+(st.report?'g':'a')+'">'+(st.report?'✓ ':'')+esc(st.stage)+'</span>'; }
  // The bar's FILL is a visual claim too, same as the badge above it: a full
  // green fill for a failed/abandoned family asserts success just as loudly
  // as the old "done" label did (same-done-miscount-in-three-more-surfaces).
  // Same d.state, same err/stale vocabulary as the badge - never re-derived.
  var barCls=d.state==='failed'?'err':(d.state==='abandoned'?'stale':'');
  var prog=d.progress.pct>0?'<div class="bprog"><i class="'+barCls+'" style="width:'+d.progress.pct+'%"></i></div>':'';
  var right = agentChip(agState) + (liveStatus ? '<span class="chipm a live">'+esc(liveStatus)+'</span>' : '<span class="live" style="margin-left:auto;color:var(--muted);font-size:10.5px">'+esc(d.progress.label)+'</span>');
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
  var wait=boardWaits(f.id, line);
  // The wait chip is the approve shortcut: it opens the dock AT this
  // family's pane (the full context lives there - a truncated preview is not
  // enough to decide on).
  var waitChip=wait?' <span class="chipm wait" data-td-open data-td-family="'+esc(f.id)+'" title="Open the dock at this roomchief&#39;s pane to answer">⏳ waiting on captain</span>':'';
  return '<a class="bcard st-'+d.state+(wait?' wait':'')+'" href="/fleets/'+enc(currentFleet())+'/board/'+enc(f.id)+'" data-link>'
    +'<div class="cid">'+esc(f.id)+badges+waitChip+inboxChips(inboxIt)+'</div>'
    +'<div class="ct">'+esc(d.text||f.id)+'</div>'
    +(cchips?'<div class="brow">'+cchips+'</div>':'')
    +(chips?'<div class="brow">'+chips+'</div>':'')
    +prog
    +'<div class="brow"><span class="chipm">repo: '+esc(d.repo||'—')+'</span>'+right+'</div>'
    +roll+subs+'</a>';
}

// A live system/paned task with no backlog row (board-live-panes): styled like
// any in-flight card (it IS running work), with its kind as a badge and its
// live status line. Transient: gone when the pane is reaped and its meta
// disappears from the snapshot.
function boardSysCard(p, agState, inboxIt){
  // A system pane's FAMILY detail is reachable like any card's: a roomchief
  // id maps to its family (room + data dir exist even with no backlog row -
  // the brainstorm shape), any other id is its own family.
  var fam=(p.kind==='roomchief' && /-chief$/.test(p.id)) ? p.id.replace(/-chief$/,'') : p.id;
  var wait=boardWaits(fam,'');
  return '<a class="bcard sys'+(wait?' wait':'')+'" href="/fleets/'+enc(currentFleet())+'/board/'+enc(fam)+'" data-link>'
    +'<div class="cid">'+esc(p.id)+' <span class="badgeb sys">'+esc(p.kind)+'</span>'+(wait?' <span class="chipm wait" data-td-open data-td-family="'+esc(fam)+'" title="Open the dock at this roomchief&#39;s pane to answer">⏳ waiting on captain</span>':'')+inboxChips(inboxIt)+'</div>'
    +'<div class="brow"><span class="chipm">repo: '+esc(p.project||'—')+'</span>'
    +agentChip(agState)
    +'<span class="chipm a live">'+esc(p.status||'—')+'</span></div>'
    +'</a>';
}

// ---- Task detail, fetched from /api/family. Same FamilyDetail shape the
// composer/bun test prove. The ROUTE owns which family is open (boardOpenFam
// only mirrors it, because the chief panel's send/paste/key paths all read it),
// so opening and closing are ordinary navigation with no imperative mount. --
function boardSyncFamily(r){
  var fam=(r && r.name==='board' && r.fam) ? r.fam : null;
  if(fam!==boardOpenFam){ boardOpenFam=fam; boardArtReq++; }
  if(!fam) return;
  var hp=r.home?r.home.path:''; if(!hp) return;   // home not resolved yet - the next render retries
  var ck=hp+'|'+fam;
  if(!(ck in familyCache) && !familyLoading[ck]){
    familyLoading[ck]=1;
    var done=function(j){ delete familyLoading[ck]; familyCache[ck]=j; if(boardOpenFam===fam) renderPage(); };
    fetch('/api/family?path='+enc(hp)+'&family='+enc(fam)).then(function(x){ return x.json(); })
      .then(function(j){ done(j||{error:'empty'}); })
      .catch(function(){ done({error:'failed to load'}); });
  }
  // The snapshot chief panel is retired - no poll to arm here any more.
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
          // which stories raised one.
          :(function(){ var pm=/\bPR #(\d+)\b/.exec(ch.text||''); return pm?'<span class="spr" title="PR number recorded on the row; no URL to open">PR '+pm[1]+'</span>':''; })())
        +(ch.repo?'<span class="srepo" title="'+esc(ch.repo)+'">'+esc(ch.repo)+'</span>':'')
        +'<span class="badge '+(STORY_BADGE[ch.state]||'')+'">'+STORY_ICON[ch.state]+' '+esc(ch.state)+'</span></a>'; }
    stories=boardOvList('ovstories','Stories', d.rollup.done+'/'+d.rollup.total+' done', srows);
  }
  // Sub-tasks (section-8 fan-out units, derived - never ledger rows): the
  // captain's answer to "which pieces ran and what did each land" without
  // reading the room prose. Slug links open the unit's report in Reports.
  var subs='';
  if(d.subtasks && d.subtasks.length){
    var done=0, subRows='';
    for(var si=0;si<d.subtasks.length;si++){ var sb=d.subtasks[si];
      var stt=sb.live?'flying':(sb.prMerged||sb.hasReport?'done':'ended');
      if(stt==='done') done++;
      // The whole row is the detail link (same /board/<id> composer renders a
      // sub-task from its own brief/report/timeline/meta); the PR chip stays
      // a delegated data-ext hop since a nested anchor is invalid.
      subRows+='<a class="strow" href="/fleets/'+enc(currentFleet())+'/board/'+enc(sb.id)+'" data-link title="'+esc(sb.id)+' detail">'
        +'<span class="stid">'+esc(sb.slug)+'</span>'
        +'<span class="sttx"></span>'
        +(sb.pr?'<span class="spr" role="link" tabindex="0" data-ext="'+esc(sb.pr)+'" title="'+esc(sb.pr)+'">PR '+esc(prNum(sb.pr)||'↗')+(sb.prMerged?' ✓':'')+'</span>':'')
        +(sb.repo?'<span class="srepo" title="'+esc(sb.repo)+'">'+esc(sb.repo)+'</span>':'')
        +'<span class="badge '+(stt==='flying'?'accent':(stt==='done'?'ok':''))+'">'+(stt==='flying'?'●':(stt==='done'?'✓':'○'))+' '+stt+'</span>'
        +'</a>'; }
    subs=boardOvList('ovsubs','Sub-tasks', done+'/'+d.subtasks.length+' done', subRows);
  }
  return '<div class="overview"><h3>'+esc(d.id)+'</h3>'
    +'<div class="ovsub">Pick an artifact on the left to view it inline here.</div>'
    +'<div class="ovrow">'+rows+'</div>'+stories+subs+pr+room+'</div>';
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
    +((d&&d.epicBranches&&d.epicBranches.length)?d.epicBranches.map(function(b){
        return '<span class="badgeb ebr'+(b.retired?' retired':'')+'" title="integration branch of '+esc(b.repo)+(b.staging?' (staging '+esc(b.staging)+')':'')+(b.push?' - push=yes':'')+(b.retired?' - RETIRED':'')+'">&#9095; '+esc(b.branch)+' &middot; '+esc(b.repo)+'</span>';
      }).join(''):'')
    +(d&&d.parent?'<a class="badgeb" href="/fleets/'+enc(currentFleet())+'/board/'+enc(d.parent)+'" data-link title="this is a fan-out sub-task of '+esc(d.parent)+'">↳ sub-task of '+esc(d.parent)+'</a>':'')
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
    +'<button class="railtg" type="button" data-rail-toggle title="'+(railCut()?'Expand the rail':'Collapse the rail')+'">'+(railCut()?'⇥':'⇤')+'</button>'
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
// Rail collapse: render-time class so a
// remount keeps the choice, imperative toggle so a poll never fights it.
function railCut(){ try{ return localStorage.getItem('ac_dash_brail')==='1'; }catch(e){ return false; } }
function railToggle(){
  var on=!railCut();
  try{ localStorage.setItem('ac_dash_brail', on?'1':'0'); }catch(e){}
  var fb=document.querySelector('.bdetail .fbody'); if(fb) fb.classList.toggle('railcut', on);
  var b=document.querySelector('.bdetail .railtg');
  if(b){ b.textContent=on?'⇥':'⇤'; b.title=on?'Expand the rail':'Collapse the rail'; }
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
  // The snapshot chief panel is retired - the terminal dock (the herdr pill)
  // is the one live-terminal surface, so the detail keeps the full width.
  return boardDetailHead(d.id, d)
    +'<div class="fbody'+(railCut()?' railcut':'')+'">'
    +boardDetailRail(d, fleet)+boardDetailViewer(d)+'</div>';
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
    // The toolbar carries the mockup-approved controls on the EXISTING
    // terminal: A-/A+ font, the sidebar toggle (widen the terminal), and the
    // open-in-own-tab hop.
    var bar='<div class="termbar">'
      +'<span class="tbtitle mono">herdr &middot; terminal</span>'
      +'<span class="tbsp"></span>'
      +'<button type="button" class="btn sm" id="tp-fminus" title="Smaller terminal font">A-</button>'
      +'<span id="tp-fsize" class="tbfs mono">&middot;</span>'
      +'<button type="button" class="btn sm" id="tp-fplus" title="Larger terminal font">A+</button>'
      +'<button type="button" class="btn sm" id="tp-side" title="Toggle the sidebar - widen the terminal">&#8676;</button>'
      +'<a class="btn sm" href="/term" target="_blank" rel="noopener" title="open in its own page">&#8599;</a>'
      +'</div>';
    return '<div class="termpage">'+bar+'<iframe src="'+esc(termUrl)+'" title="herdr terminal"></iframe></div>';
  }
  return '<div class="termpage"><div class="cdead">'+esc(termWhy)+'</div></div>';
}
function termFrameWin(){ var f=document.querySelector('.termpage iframe'); return f?f.contentWindow:null; }
function termFont(d){
  var w=termFrameWin();
  if(w && typeof w.acSetFont==='function'){ var v=w.acSetFont(d); var s=el('tp-fsize'); if(s) s.textContent=String(v); }
}
function termFontLabel(){
  var w=termFrameWin(); var s=el('tp-fsize');
  if(w && s && typeof w.acGetFont==='function'){ try{ s.textContent=String(w.acGetFont()); }catch(e){} }
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
// Paint the terminal frame in the page's OWN theme (the webterm background
// must match the page). The frame is same-origin, so this is a direct call into the
// function it exposes - never a remount, which would kill the herdr client.
// Deduped on the pair, so the per-poll renderPage never repaints for nothing.
// The mapping itself lives in the shared termThemeCore (interpolated below) -
// one implementation for this tab AND the standalone /term page.
${termThemeCore.toString()}
var termBg='';
function termTheme(){
  // Every terminal surface present (the Terminal tab AND the dock) gets the
  // page theme; the dedupe sig only advances when all took the paint, so a
  // dock mounted later still gets its coat.
  var fs=document.querySelectorAll('.termpage iframe, #td-body iframe'); if(!fs.length) return;
  var r=termThemeCore(getComputedStyle(document.documentElement));
  if(!r || r.sig===termBg) return;
  var ok=true;
  for(var i=0;i<fs.length;i++){
    var w=fs[i].contentWindow;
    if(w && typeof w.acSetTheme==='function') w.acSetTheme(r.theme); else ok=false;
  }
  if(ok) termBg=r.sig;
}
// ---- Terminal dock (every route except the Terminal page). OUR backend untouched: the iframe is the same
// /term-frame client the Terminal tab mounts. The one exclusion is BY
// CONSTRUCTION: tdRouteOk() gates open, and applyRoute closes the dock on
// entering 'term' - so the dock can never coexist with the /terminal page's
// own client (the two-full-clients lag that reverted the v2 GLOBAL dock).
var tdMode='closed', tdW=480, tdIntent='';
// tdIntent is the CAPTAIN'S standing choice (open as split/full, or ''), kept
// apart from tdMode because route exclusions close the dock without the
// captain asking - the intent is what survives a reload and what reopens the
// dock after the /terminal page's structural close.
try{ var tds=JSON.parse(localStorage.getItem('ac_term_dock')||'{}'); if(tds.w) tdW=tds.w; if(tds.mode==='split'||tds.mode==='full') tdIntent=tds.mode; }catch(e){}
function tdPersist(){ try{ localStorage.setItem('ac_term_dock', JSON.stringify({w:tdW, mode:tdIntent})); }catch(e){} }
// Every route carries the dock EXCEPT the Terminal page - that page mounts its own full client, and dock
// + page together is the measured two-clients lag that reverted the v2
// global dock. Entering 'term' closes the dock; the page shows the same
// herdr session anyway.
function tdRouteOk(){ return !!(S.route && S.route.name!=='term'); }
function tdApply(){
  var d=el('term-dock'); if(!d) return;
  d.hidden = tdMode==='closed';
  d.classList.toggle('full', tdMode==='full');
  d.classList.toggle('hid', tdMode==='hidden');
  // The pill is the dock's ONLY entry point (the header button is gone): it
  // shows on every carrying route whenever the dock itself is not on screen -
  // closed (click opens a fresh session) or hidden (click restores the live
  // one).
  var rl=el('td-rail'); if(rl) rl.hidden = !((tdMode==='closed'||tdMode==='hidden') && tdRouteOk());
  document.documentElement.style.setProperty('--tdw', tdW+'px');
  document.body.classList.toggle('term-docked', tdMode==='split');
  var fb=el('td-full'); if(fb) fb.setAttribute('aria-pressed', tdMode==='full'?'true':'false');
}
function tdFrameWin(){ var f=document.querySelector('#td-body iframe'); return f?f.contentWindow:null; }
function tdMount(){
  var b=el('td-body'); if(!b||b.firstChild) return;
  var hp=S.route&&S.route.home?S.route.home.path:'';
  if(!hp){ var th=fleetByName(S.snap, currentFleet()); hp=th?th.path:''; }
  if(!hp){
    // Boot race: the dock can open before the first snapshot resolves a home
    // (retired-chat redirect does exactly this). The placeholder must not
    // satisfy the firstChild mount guard forever - clear it and retry.
    b.innerHTML='<div class="cdead">resolving fleet home&hellip;</div>';
    setTimeout(function(){
      var bb=el('td-body');
      if(bb && tdMode!=='closed' && !bb.querySelector('iframe')){ bb.innerHTML=''; tdMount(); }
    }, 900);
    return;
  }
  fetch('/api/term/status?path='+enc(hp)).then(function(r){ return r.json(); }).then(function(j){
    var bb=el('td-body'); if(!bb||bb.firstChild) return;
    if(j.running&&j.url){
      var f=document.createElement('iframe'); f.src=j.url+tdScope; f.title='herdr terminal';
      bb.appendChild(f);
      // Never a silent blank: the overlay stands until the frame's first pty
      // byte (acTermLive below) - the frame's own watchdog respawns a silent
      // connection, so this converges to a live terminal, not a spinner.
      var ov=document.createElement('div'); ov.className='tdload'; ov.id='td-load';
      ov.innerHTML='<span>connecting to herdr&hellip;</span>';
      bb.appendChild(ov);
      termBg=''; setTimeout(function(){ termTheme(); tdFontLabel(); }, 800);
    } else if(j.orca){
      bb.innerHTML='<div class="cdead">'+esc(j.why||'this fleet runs on the Orca app')+' · <a href="#" onclick="return acOrcaOpen()">open Orca</a></div>';
    } else bb.innerHTML='<div class="cdead">'+esc(j.why||j.error||'terminal unavailable')+'</div>';
  }).catch(function(){ var bb=el('td-body'); if(bb&&!bb.firstChild) bb.innerHTML='<div class="cdead">terminal unreachable</div>'; });
}
function tdOpen(mode){ tdMode=mode; tdIntent=mode; tdPersist(); tdApply(); tdMount(); }
// Workspace scope for the dock's client: '' = plain, '&fleet=1' = the
// crewchief's workspace, '&family=<f>' = that family's workspace (the
// /term-frame scope machinery types the picker chord itself). A scope CHANGE
// remounts the iframe so the new client opens at the right workspace; the
// same scope just re-raises the running session.
var tdScope='';
function tdOpenScoped(sc){
  if(sc!==tdScope){ tdScope=sc; var b=el('td-body'); if(b) b.innerHTML=''; }
  tdOpen('split');
}
// The frame's first pty byte lands here (same-origin direct call): drop the
// dock's connecting overlay. The Terminal tab calls it too - harmless no-op.
window.acTermLive=function(){ var o=el('td-load'); if(o) o.remove(); };
// user=false is a STRUCTURAL close (route exclusion) - the captain's intent
// stands and the next carrying route reopens; only the captain's own X
// clears it.
function tdClose(user){ tdMode='closed'; tdApply(); var b=el('td-body'); if(b) b.innerHTML=''; if(user!==false){ tdIntent=''; tdPersist(); } }
function tdFont(d){
  var w=tdFrameWin();
  if(w && typeof w.acSetFont==='function'){ var v=w.acSetFont(d); var sp=el('td-fsize'); if(sp) sp.textContent=String(v); }
}
function tdFontLabel(){
  var w=tdFrameWin(); var sp=el('td-fsize');
  if(w && sp && typeof w.acGetFont==='function'){ try{ sp.textContent=String(w.acGetFont()); }catch(e){} }
}
(function(){
  var g=el('td-grip'); if(!g) return;
  var drag=false, sx=0, sw=0, raf=0;
  g.addEventListener('mousedown', function(e){
    drag=true; sx=e.clientX; sw=tdW; e.preventDefault();
    document.body.classList.add('td-dragging');
  });
  addEventListener('mousemove', function(e){
    if(!drag) return;
    tdW=Math.max(320, Math.min(Math.floor(innerWidth*0.72), sw+(sx-e.clientX)));
    // One CSS-var write per FRAME, and only the var: the full tdApply pass
    // (class toggles, pill state) at mousemove rate is what made this janky.
    if(!raf) raf=requestAnimationFrame(function(){ raf=0; document.documentElement.style.setProperty('--tdw', tdW+'px'); });
  });
  addEventListener('mouseup', function(){
    if(!drag) return;
    drag=false; document.body.classList.remove('td-dragging');
    if(raf){ cancelAnimationFrame(raf); raf=0; }
    tdApply();
    tdPersist();
  });
})();
// Ctrl+backtick toggles the dock on the screens that carry it; Esc drops
// fullscreen to split. Both fire only with focus OUTSIDE the terminal frame -
// inside it, every key belongs to the pty.
addEventListener('keydown', function(e){
  if(e.ctrlKey && e.key==='\u0060' && tdRouteOk()){ e.preventDefault(); (tdMode==='closed'||tdMode==='hidden')?tdOpen('split'):tdClose(); return; }
  if(e.key==='Escape' && tdMode==='full') tdOpen('split');
});
function termPoll(){
  // Top-level /terminal has no fleet in the route: herdr is one session
  // machine-wide, so any known home path satisfies the server's gate.
  var hp=S.route&&S.route.home?S.route.home.path:'';
  if(!hp){ var th=fleetByName(S.snap, currentFleet()); hp=th?th.path:''; }
  if(!hp) return;
  fetch('/api/term/status?path='+enc(hp)).then(function(r){ return r.json(); }).then(function(j){
    if(!S.route||S.route.name!=='term'){ clearTimeout(termT); termT=null; return; }
    if(j.running&&j.url){ if(termUrl!==j.url){ termUrl=j.url; renderPage(); setTimeout(termFontLabel, 900); } return; }
    termUrl=null; termWhy=j.why||j.error||'unavailable'; renderPage();
    termT=setTimeout(termPoll, 1500);
  }).catch(function(){ termT=setTimeout(termPoll, 3000); });
}

// The chat route is retired (applyRoute/boot redirect it to the board with
// the dock up); this stub only covers a render squeezed in before redirect.
function pageChat(){ return ''; }
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
            if(j.ok) chiefNote('image saved + path typed into pane — add a message then Enter to send');
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
function acOrcaOpen(id){
  fetch('/api/orca/focus?path='+enc(hp)+(id?'&id='+enc(id):''), {method:'POST'}).catch(function(){});
  return false;
}
function chiefFrame(j){
  var t=el('chief-term'), st=el('chief-state'); if(!t||!st) return;
  if(j.inputError){ chiefNote('refused: '+j.inputError, true); return; }
  if(!j.live){
    if(j.orca){ st.innerHTML=esc(j.why||'runs on the Orca app')+' · <a href="#" data-orca="'+esc(j.orca)+'" onclick="return acOrcaOpen(this.dataset.orca)">open in Orca</a>'; return; }
    st.textContent=j.why||'not live'; return; }
  st.textContent=(j.readonly?'live · watching '+chiefWatch:'live · type here')+' · stream';
  var htmlChanged = t._h!==j.html;
  // A pure resize (server's true cols moved, pane text did not) still needs a
  // refit - html-only dedupe would leave the OLD font stuck until the pane's
  // text next changes.
  if(!htmlChanged && t._trueCols===j.cols) return;
  var pinned = t.scrollTop + t.clientHeight >= t.scrollHeight - 8;
  var fromBottom = t.scrollHeight - t.scrollTop;
  if(htmlChanged){
    t._h=j.html;
    // Box-drawing separator rows are drawn at the pane's own column width;
    // wider than the panel they would soft-wrap and leave a stub line under
    // each rule - keep every run on one line, clipped at the panel edge.
    t.innerHTML=(j.html||'').replace(/─{20,}/g, '<span class="csep">$&</span>');
  }
  t._trueCols=j.cols;
  // Auto-fit (no horizontal scroll): prefer the pane's REAL column count
  // (herdr pane layout, resolved server-side) over inferring it from
  // box-drawing separator runs - a TUI that draws a rule wider than its own
  // pty (or "recent-unwrapped" rejoining several stacked separator lines
  // into one) inflates that guess past the true width. Fall back to the old
  // text heuristic only when the server could not resolve one.
  var cols=j.cols>0?j.cols:0;
  if(!cols){
    var runs=(t.textContent||'').match(/─{20,}/g)||[];
    for(var li2=0;li2<runs.length;li2++){ if(runs[li2].length>cols) cols=runs[li2].length; }
    cols=Math.min(cols, 240);
    if(!cols) cols=t._cols||100;
  }
  if(cols!==t._cols || Math.abs((t._w||0)-t.clientWidth)>4){
    t._cols=cols; t._w=t.clientWidth;
    t.style.fontSize=chiefFitPx(cols, t.clientWidth).toFixed(2)+'px';
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
  if((chiefSock||chiefTimer) && chiefCur===target){
    // Same target keeps its transport - but the tabs strip can still be BARE:
    // board detail arms this BEFORE the panel's DOM is morphed in (the first
    // chiefLoadTabs found no #chief-tabs and gave up), so repopulate whenever
    // the strip exists empty. Chat mounts the panel up front and never hits it.
    var tb=el('chief-tabs');
    if(target!==true && tb && !tb.firstChild) chiefLoadTabs();
    return;
  }
  chiefPollStop(); chiefCur=target; chiefLines=400;
  if(!keepWatch){ try{ chiefWatch=localStorage.getItem(chiefWatchKey(target))||''; }catch(e){ chiefWatch=''; } }   // a NEW target restores its remembered pick
  if(target!==true) setTimeout(chiefLoadTabs, 0);   // family targets get the linked-pane chips; deferred past the morph that mounts the panel
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
// ---- Worktrees tab (dash-source-control): the ac-tree POOL is the truth of
// worktrees - one collapsible section per leased slot (a multi-repo task
// shows each of its trees; a lease that outlived its task meta still shows).
// Each section renders the three SCM groups (changes / untracked / committed
// on branch), file cards closed until clicked. A loaded section is a
// preserved island keyed on its load states, so toggles survive polling.
var SC_GROUPS=[['uncommitted','Changes'],['untracked','Untracked files'],['committed','Committed on branch']];
var scDiff={};   // hp|id|tree|mode -> {loading} | {error} | {empty:1} | {html,add,del,files}
function scLoad(hp,id,tree,mode,ref){
  var ck=hp+'|'+id+'|'+tree+'|'+mode+'|'+(ref||''); if(scDiff[ck]) return;
  scDiff[ck]={loading:1};
  var settle=function(e){ scDiff[ck]=e; if(S.route&&S.route.name==='worktrees') renderPage(); };
  fetch('/api/diff?path='+enc(hp)+'&id='+enc(id)+'&mode='+enc(mode)+(tree?'&tree='+enc(tree):'')+(ref?'&ref='+enc(ref):'')).then(function(x){ return x.json(); }).then(function(j){
    if(j.error) return settle({error:j.error});
    if(!j.diff||!j.diff.trim()) return settle({empty:1});
    if(mode==='graph') return settle({html:graphHtml(j.diff), add:0, del:0, files:0, graph:1});
    var st=diffStats(j.diff);
    settle({html:diffHtml(j.diff,true)+(j.truncated?'<div class="dfnote">diff truncated at 400KB - read the rest with bin/ac-review-diff.sh '+esc(id)+'</div>':''),
        add:st.add, del:st.del, files:st.files});
  }).catch(function(){ settle({error:'request failed'}); });
}
function scState(d){ return !d||d.loading?'l':(d.error?'x':(d.empty?'0':'k')); }
var scWanted={};   // hp|tree -> 1 once an AVAILABLE section was opened (its loads are click-driven, never eager)
var scGraphRef={}; // hp|repo -> the branch picker's choice ('' = all branches)
var scPull={};     // hp|repo -> 'busy' | last result line (the Pull button's state)
function scPullRun(hp, repo){
  var k=hp+'|'+repo; if(scPull[k]==='busy') return;
  scPull[k]='busy'; renderPage();
  fetch('/api/repo/pull?path='+enc(hp)+'&repo='+enc(repo), {method:'POST'}).then(function(x){ return x.json(); }).then(function(j){
    scPull[k]=j.error?('error: '+j.error):j.result;
    scDiff={};   // every cached diff/graph may be stale after a sync
    renderPage();
  }).catch(function(){ scPull[k]='error: request failed'; renderPage(); });
}
// Graph click-through: a row toggles that commit's own diff inline under it.
function ggToggleCommit(row){
  var next=row.nextElementSibling;
  if(next&&next.className==='ggdiff'){ next.parentNode.removeChild(next); return; }
  var sec=row.closest('[data-sc-tree]'); if(!sec) return;
  var hp=sec.getAttribute('data-sc-hp')||'', id=sec.getAttribute('data-sc-id')||'', tree=sec.getAttribute('data-sc-tree')||'', sha=row.getAttribute('data-sha')||'';
  var box=document.createElement('div'); box.className='ggdiff'; box.innerHTML=skeleton();
  row.parentNode.insertBefore(box, row.nextSibling);
  fetch('/api/diff?path='+enc(hp)+'&id='+enc(id)+'&mode=commit&sha='+enc(sha)+(tree?'&tree='+enc(tree):'')).then(function(x){ return x.json(); }).then(function(j){
    if(!box.parentNode) return;
    box.innerHTML=j.error?stateBox('No diff', j.error, ''):(j.diff&&j.diff.trim()?diffHtml(j.diff):stateBox('Empty commit','no textual change',''));
  }).catch(function(){ if(box.parentNode) box.innerHTML=stateBox('Diff unavailable','request failed',''); });
}
// Branch picker (the GitKraken shape): a searchable dropdown, built
// imperatively INSIDE the graph's preserved island so typing survives the
// poll re-render. Picking a branch re-renders; picking again toggles closed.
function ggPickerOpen(btn){
  var host=btn.closest('.ggpick'); if(!host) return;
  var ex=host.querySelector('.ggpanel'); if(ex){ ex.parentNode.removeChild(ex); return; }
  var gkey=btn.getAttribute('data-gg-pick');
  var repo=gkey.slice(gkey.indexOf('|')+1);
  var brs=(S.page&&S.page.branches)||[], names=[''];
  for(var i=0;i<brs.length;i++) if(brs[i].repo===repo) names.push(brs[i].branch);
  var p=document.createElement('div'); p.className='ggpanel';
  var inp=document.createElement('input'); inp.className='ggsearch'; inp.type='text'; inp.placeholder='Search branches'; p.appendChild(inp);
  var listEl=document.createElement('div'); listEl.className='ggopts'; p.appendChild(listEl);
  function fill(q){
    listEl.innerHTML='';
    for(var k=0;k<names.length;k++){ var nm=names[k], lbl=nm||'All branches';
      if(q && lbl.toLowerCase().indexOf(q)<0) continue;
      var o=document.createElement('div');
      o.className='ggopt'+(nm.indexOf('crew/')===0?' crew':'');
      o.textContent=lbl;
      (function(v){ o.addEventListener('click', function(){ scGraphRef[gkey]=v; renderPage(); }); })(nm);
      listEl.appendChild(o);
    }
    if(!listEl.firstChild){ var z=document.createElement('div'); z.className='ggopt muted'; z.textContent='no match'; listEl.appendChild(z); }
  }
  fill('');
  inp.addEventListener('input', function(){ fill(inp.value.toLowerCase()); });
  host.appendChild(p); inp.focus();
}
// Lane click: spotlight that branch line through the whole graph; same lane
// again clears it.
function ggFocusLane(hit){
  var gg=hit.closest('.gg'); if(!gg) return;
  var lane=hit.getAttribute('data-lane'), cur=gg.getAttribute('data-flane');
  var els=gg.querySelectorAll('.gl'), i;
  if(cur===lane){ gg.removeAttribute('data-flane'); for(i=0;i<els.length;i++) els[i].classList.remove('dim'); return; }
  gg.setAttribute('data-flane', lane);
  for(i=0;i<els.length;i++) els[i].classList.toggle('dim', els[i].getAttribute('data-lane')!==lane);
}
function scSection(hp, pl){
  // An available slot's LAST task still names the crew branch its tree may
  // hold; a slot that never leased falls back to the slot name (same charset).
  var id=pl.task||pl.slot, tree=pl.worktree;
  var ds={}, states='', tAdd=0, tDel=0, tFiles=0, loading=false;
  for(var g=0;g<SC_GROUPS.length;g++){ var mk=SC_GROUPS[g][0], d=scDiff[hp+'|'+id+'|'+tree+'|'+mk+'|'];
    if(!d) scLoad(hp, id, tree, mk);
    d=scDiff[hp+'|'+id+'|'+tree+'|'+mk+'|']; ds[mk]=d; states+=scState(d);
    if(!d||d.loading) loading=true;
    else if(d.html){ tAdd+=d.add; tDel+=d.del; tFiles+=d.files; }
  }
  var badge = loading ? '<span class="muted">loading&hellip;</span>'
    : ds.committed&&ds.committed.error ? '<span class="badge warn">no diff</span>'
    : !tFiles ? '<span class="muted">clean</span>'
    : '<span class="n na">+'+tAdd+'</span> <span class="n nd">-'+tDel+'</span> <span class="muted">'+tFiles+' file'+(tFiles===1?'':'s')+'</span>';
  var body='';
  if(ds.committed&&ds.committed.error){ body=stateBox('No diff', ds.committed.error, ''); }
  else if(loading){ body=skeleton(); }
  else if(!tFiles){ body='<div class="muted" style="padding:6px 0 2px">worktree clean - no change against its base</div>'; }
  else{
    for(var g2=0;g2<SC_GROUPS.length;g2++){ var mk2=SC_GROUPS[g2][0], d2=ds[mk2];
      if(!d2||!d2.html) continue;
      body+='<div class="scgroup"><span class="scgh">'+SC_GROUPS[g2][1]+'</span> <span class="scgn">'+d2.files+'</span></div>'+d2.html;
    }
  }
  var avail=pl.state!=='leased'?' <span class="badge">available</span>':'';
  var headChip=pl.head?' <span class="gghead'+(pl.head.indexOf('detached')===0?' det':'')+'">'+esc(pl.head)+'</span>':'';
  // Title = the WORKTREE (slot) + its branch chip; the task is context, not
  // identity - the repo is already the group heading above.
  return '<details class="sctask" open data-preserve="sc|'+esc(hp)+'|'+esc(id)+'|'+esc(tree)+'|'+states+'">'
    +'<summary><span class="mono scid">'+esc(pl.slot)+'</span>'+headChip
    +(pl.task?' <span class="muted" style="font-size:11px">'+esc(pl.task)+'</span>':'')+avail
    +'<span class="scmeta">'+badge+'</span></summary>'
    +'<div class="scbody">'+body+'</div></details>';
}
// A crew/* branch no worktree is standing on: a finished task's code parked
// in the repo, waiting to land. Committed diff only - there is no working
// tree to read.
function scBranchSection(hp, cb){
  var id=cb.branch.slice(5), tree=cb.root;
  var ck=hp+'|'+id+'|'+tree+'|committed|', d=scDiff[ck];
  if(!d) scLoad(hp, id, tree, 'committed');
  d=scDiff[ck];
  var badge=!d||d.loading?'<span class="muted">loading&hellip;</span>'
    : d.error?'<span class="badge warn">no diff</span>'
    : d.empty?'<span class="muted">tip equals base</span>'
    : '<span class="n na">+'+d.add+'</span> <span class="n nd">-'+d.del+'</span> <span class="muted">'+d.files+' file'+(d.files===1?'':'s')+'</span>';
  var body=d&&d.html?d.html:(d&&d.error?stateBox('No diff', d.error, ''):(d&&d.empty?'<div class="muted" style="padding:6px 0 2px">branch tip equals its base - nothing unlanded</div>':skeleton()));
  return '<details class="sctask" open data-preserve="scb|'+esc(hp)+'|'+esc(id)+'|'+esc(tree)+'|'+scState(d)+'">'
    +'<summary><span class="ggref crew">'+esc(cb.branch)+'</span>'
    +' <span class="muted" style="font-size:11px">'+esc(cb.sha.slice(0,7))+' &middot; parked, waiting to land</span>'
    +'<span class="scmeta">'+badge+'</span></summary>'
    +'<div class="scbody">'+body+'</div></details>';
}
function pageWorktrees(){
  var r=S.route, hp=r.home?r.home.path:'';
  var pools=(S.page&&S.page.pools)||[], rows=[], idle=[];
  for(var i=0;i<pools.length;i++){ var p=pools[i]; if(!p.worktree) continue; (p.state==='leased'?rows:idle).push(p); }
  if(!rows.length&&!idle.length) return S.page?stateBox('No pooled worktrees','the ac-tree pool is empty - trees appear here once crew work leases them',''):skeleton();
  // Grouped BY REPO (the workspace-panel shape): one heading per repo, its
  // leased trees open under it, its available trees folded per repo.
  var repos={}, order=[];
  for(var g0=0;g0<rows.length;g0++){ var rp=rows[g0].repo; if(!repos[rp]){ repos[rp]={leased:[],idle:[],used:0}; order.push(rp); } repos[rp].leased.push(rows[g0]); }
  for(var g1=0;g1<idle.length;g1++){ var ip0=idle[g1]; if(!repos[ip0.repo]){ repos[ip0.repo]={leased:[],idle:[],used:0}; order.push(ip0.repo); } repos[ip0.repo].idle.push(ip0); }
  // Recency order, never alphabetical: the repo you are WORKING comes first.
  // used_at is the slot-meta mtime, which every lease/return touches.
  function byUsed(a,b){ return (b.used_at||0)-(a.used_at||0); }
  for(var g5=0;g5<order.length;g5++){ var gg=repos[order[g5]];
    gg.leased.sort(byUsed); gg.idle.sort(byUsed);
    gg.used=Math.max(gg.leased.length?gg.leased[0].used_at||0:0, gg.idle.length?gg.idle[0].used_at||0:0);
  }
  order.sort(function(a,b){ return repos[b].used-repos[a].used; });
  var ui=uiFor(routeKey(r));
  var s='<div class="scwrap"><div class="dflive">the ac-tree worktree pool - every leased tree, uncommitted work included</div>';
  for(var g2=0;g2<order.length;g2++){ var rp2=order[g2], grp=repos[rp2];
    var pk=hp+'|'+rp2, pst=scPull[pk]||'';
    s+='<section class="screpogrp"><div class="screpo"><span class="srname">'+esc(rp2)+'</span>'
      +'<span class="srtools">'
      +(pst&&pst!=='busy'?'<span class="muted" style="font-size:11px">'+esc(pst)+'</span>':'')
      +'<button type="button" class="fopen mono" data-repo-pull="'+esc(rp2)+'"'+(pst==='busy'?' disabled':'')+' title="git fetch + fast-forward-only sync">'+(pst==='busy'?'pulling&hellip;':'&#8635; pull')+'</button>'
      +'</span></div><div class="screpob">';
    for(var k=0;k<grp.leased.length;k++) s+=scSection(hp, grp.leased[k]);
    // Available slots fold per repo, and each section fetches only once
    // OPENED - an idle pool must cost zero requests.
    if(grp.idle.length){
      var dk='scavail:'+rp2, showIdle=!!ui.exp[dk];
      s+='<button class="btn sm" data-disc="'+esc(dk)+'" aria-expanded="'+(showIdle?'true':'false')+'" style="margin:2px 0 8px">'+(showIdle?'Hide':'Show')+' '+grp.idle.length+' available</button>';
      if(showIdle) for(var k2=0;k2<grp.idle.length;k2++){ var ip=grp.idle[k2], wk=hp+'|'+ip.worktree;
        if(scWanted[wk]) s+=scSection(hp, ip);
        else s+='<details class="sctask" data-preserve="sc|'+esc(hp)+'|'+esc(ip.worktree)+'|idle"><summary data-sc-want="'+esc(wk)+'"><span class="mono scid">'+esc(ip.slot)+'</span>'
          +(ip.head?' <span class="gghead'+(ip.head.indexOf('detached')===0?' det':'')+'">'+esc(ip.head)+'</span>':'')
          +(ip.task?' <span class="muted" style="font-size:11px">'+esc(ip.task)+'</span>':'')
          +' <span class="badge">available</span>'
          +'<span class="scmeta"><span class="muted">open to inspect</span></span></summary></details>';
      }
    }
    // Code parked on crew/* branches no tree is standing on (the pool resets
    // trees on return, but the branch keeps the unlanded work). Folded, and
    // each loads only when opened.
    var allbrs=(S.page&&S.page.branches)||[], rbrs=[], heads={}, parked=[];
    for(var h1=0;h1<grp.leased.length;h1++) if(grp.leased[h1].head) heads[grp.leased[h1].head]=1;
    for(var h2=0;h2<grp.idle.length;h2++) if(grp.idle[h2].head) heads[grp.idle[h2].head]=1;
    for(var cb1=0;cb1<allbrs.length;cb1++){ var cb=allbrs[cb1];
      if(cb.repo!==rp2) continue;
      rbrs.push(cb);
      if(cb.branch.indexOf('crew/')===0&&!heads[cb.branch]) parked.push(cb);
    }
    if(parked.length){
      var bk='scbr:'+rp2, showBr=!!ui.exp[bk];
      s+='<button class="btn sm" data-disc="'+esc(bk)+'" aria-expanded="'+(showBr?'true':'false')+'" style="margin:2px 0 8px">'+(showBr?'Hide':'Show')+' '+parked.length+' parked crew branch'+(parked.length>1?'es':'')+'</button>';
      if(showBr) for(var cb2=0;cb2<parked.length;cb2++){ var pb=parked[cb2], wk3=hp+'|'+pb.root+'|'+pb.branch;
        if(scWanted[wk3]) s+=scBranchSection(hp, pb);
        else s+='<details class="sctask" data-preserve="scb|'+esc(hp)+'|'+esc(pb.branch)+'|idle"><summary data-sc-want="'+esc(wk3)+'"><span class="ggref crew">'+esc(pb.branch)+'</span>'
          +' <span class="muted" style="font-size:11px">'+esc(pb.sha.slice(0,7))+' &middot; parked, waiting to land</span>'
          +'<span class="scmeta"><span class="muted">open to inspect</span></span></summary></details>';
      }
    }
    // ONE graph per repo (the GitLens/GitKraken shape), with a branch picker:
    // All branches by default, or one branch's own history. Loads only when
    // opened - ten repos of eager topology is poll poison.
    if(rbrs.length){
      // Default focus = the repo's default branch (its clone HEAD); the ''
      // All-branches view stays one pick away. The in-operator check keeps a
      // deliberate All choice distinct from never-picked.
      var gdef=''; for(var gd0=0;gd0<rbrs.length;gd0++) if(rbrs[gd0].def){ gdef=rbrs[gd0].branch; break; }
      var gkey=hp+'|'+rp2, gref=(gkey in scGraphRef)?scGraphRef[gkey]:gdef, gwant=scWanted['g:'+gkey];
      if(!gwant){
        s+='<details class="scgraph srepo" data-preserve="scg|'+esc(hp)+'|'+esc(rp2)+'|idle"><summary data-sc-want="g:'+esc(gkey)+'">Graph</summary></details>';
      } else {
        var groot=rbrs[0].root, gid=rp2, gck=hp+'|'+gid+'|'+groot+'|graph|'+gref, gd=scDiff[gck];
        if(!gd) scLoad(hp, gid, groot, 'graph', gref);
        gd=scDiff[gck];
        var gbody=gd&&gd.html?gd.html:(gd&&gd.error?stateBox('No graph', gd.error, ''):(gd&&gd.empty?'<div class="muted" style="padding:6px 0 2px">no commits</div>':skeleton()));
        s+='<details class="scgraph srepo" open data-preserve="scg|'+esc(hp)+'|'+esc(rp2)+'|'+esc(gref)+'|'+scState(gd)+'"'
          +' data-sc-hp="'+esc(hp)+'" data-sc-id="'+esc(gid)+'" data-sc-tree="'+esc(groot)+'">'
          +'<summary>Graph</summary>'
          +'<div class="scgbody"><div class="ggpick"><button type="button" class="ggsel ggselbtn" data-gg-pick="'+esc(gkey)+'">'+esc(gref||'All branches')+' <span class="muted">&#9662;</span></button></div>'+gbody+'</div></details>';
      }
    }
    s+='</div></section>';
  }
  return s+'</div>';
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
  // This content lands outside renderPage()'s morph/postFrames cycle (a direct
  // fetch().then() innerHTML set), so a mermaid fence here would otherwise
  // sit unrendered until the next POLL_MS tick catches it via postFrames -
  // fire the pass immediately instead, same as the Reports viewer already
  // gets via loadViewerBody's own explicit renderPage() call.
  postMermaid();
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
// Active-only view filter (per-fleet only, no all-homes
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
  else if(tree) list+=artTree(groupArtifacts(stemRegroup(shown)), r, ui, !!q||flt!=='all', 0);
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
// Material-icon-theme style tree icons, self-contained:
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
  if(d.backlog) s+=' <span class="muted" style="font-size:12px">queued '+d.backlog.queued+' &middot; in flight '+d.backlog.inFlight+' &middot; done '+d.backlog.done+'</span>'
    +' <a class="chip" href="/fleets/'+enc(S.route.fleet)+'/board" data-link data-jumpq="domain:'+esc(d.id)+'" title="Open the Board filtered to this domain rows">Board &rarr;</a>';
  s+='</summary>';
  s+='<div class="tblwrap" style="margin-top:10px"><table class="tbl"><tbody>';
  s+='<tr><th>records/projects.md</th><td>'+domainMemberBadge(d.members.projectsDoc)+'</td><th>CREWMATE.md</th><td>'+domainMemberBadge(d.members.crewmate)+'</td></tr>';
  s+='<tr><th>projects/ links</th><td>'+d.projects.length+'</td><th>backlog</th><td><span class="muted">fleet ledger rows tagged domain:'+esc(d.id)+'</span></td></tr>';
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
// The engine stamps last_sync in UTC; the captain reads a wall clock.
function brainLocalTs(iso){
  var d=new Date(String(iso).replace(' ','T').replace(/Z?$/,'Z'));
  if(isNaN(d)) return String(iso).slice(0,16).replace('T',' ');
  var p=function(n){ return (n<10?'0':'')+n; };
  return d.getFullYear()+'-'+p(d.getMonth()+1)+'-'+p(d.getDate())+' '+p(d.getHours())+':'+p(d.getMinutes());
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
    +'<div class="kpi"><b>'+esc(st.last_sync?brainLocalTs(st.last_sync):'never')+'</b><span>last sync</span></div>'
    +'</div>'
    +'<div class="cfg-note">Semantic search / synthesize keys: <a href="/fleets/'+enc(S.route.fleet)+'/config" data-link>Config \u2192 Brain LLM providers</a></div>';
  s+='<div style="margin:10px 0"><input class="search-in" type="search" data-brain-q placeholder="Ask the brain\u2026" aria-label="Ask the brain" autocomplete="off" spellcheck="false" value="'+esc(brainQ[hp]||'')+'" style="width:60%;max-width:520px"> '
    +'<button class="btn sm primary" data-brain-go title="Hybrid search - instant, free">Recall</button> '
    +'<button class="btn sm" data-brain-ask title="LLM-composed answer with citations - costs tokens, takes seconds">Ask (LLM)</button>'
    +(brainBusy?' <span class="badge">searching\u2026</span>':'')
    +(brainAskBusy?' <span class="badge warn">composing\u2026</span>':'')+'</div>';
  if(brainAns){
    // The synthesized answer arrives as light markdown - render bold and code
    // spans over ESCAPED text (never raw HTML), keep paragraphs (brain-ui).
    var ans=esc(brainAns.answer||'')
      .replace(/\\*\\*([^*]+)\\*\\*/g,'<b>$1</b>')
      .replace(/\`([^\`]+)\`/g,'<code class="mono" style="background:var(--elev);border-radius:4px;padding:0 4px;font-size:12px">$1</code>');
    s+='<div class="brainans"><div class="fname">Answer <span class="badge">'+esc(brainAns.synthesis_status||'')+'</span></div>'
      +'<div class="atext">'+ans+'</div>';
    var src=brainAns.sources||[];
    if(src.length){ s+='<div class="asrc">';
      for(var si=0;si<src.length;si++){ s+='<a class="srcchip" href="/review?path='+enc(hp)+'&file='+enc(hp+'/'+(src[si].path||''))+'" target="_blank" title="'+esc(src[si].path||'')+'">'+esc(src[si].slug)+'</a>'; }
      s+='</div>'; }
    s+='</div>';
  }
  var res=brainRes;
  if(res && res.results && res.results.length){
    if(res.search_degraded) s+='<div class="cfg-note">degraded: '+esc(res.search_degraded)+'</div>';
    for(var i=0;i<res.results.length;i++){ var h=res.results[i];
      var link='/review?path='+enc(hp)+'&file='+enc(hp+'/'+(h.path||''));
      // Block card, not the cfg two-column grid: the title owns one full line
      // and the snippet the next - the narrow-name-column squeeze is the same
      // defect the facts block already fixed (brain-ui).
      s+='<div class="brainhit"><div class="bh1"><a href="'+esc(link)+'" target="_blank">'+esc(h.title||h.slug)+'</a>'
        +'<span class="chipm">'+esc(h.evidence||'')+'</span>'
        +'<span class="chipm'+(String(h.trust||'').indexOf('L1')===0?' g':'')+'" title="'+esc(h.trust||'')+'">'+esc(String(h.trust||'').split(' ')[0])+'</span>'
        +'<span class="ts mono" style="margin-left:auto;font-size:11px" title="'+esc(h.path||'')+'">'+esc(h.slug)+'</span></div>'
      +((h.snippet)?'<div class="bh2">'+esc((h.snippet||'').slice(0,300))+'</div>':'')
      +'</div>';
    }
  } else if(res && res.results && (brainQ[hp]||'')){ s+='<div class="cfg-note">No hits for this query - try broader terms, or Ask (LLM) to compose across pages.</div>'; }
  // Nothing typed: the engine answers an empty query with a browse of the
  // store (newest 50 pages + page_count), so the page shows what the brain
  // holds instead of an empty box; each row deep-links into /review like a
  // hit does.
  var pgs=(res&&res.pages&&res.pages.length&&!(brainQ[hp]||''))?res.pages:null;
  if(pgs){
    s+='<h2 style="font-size:14px;margin:14px 0 6px">Pages <span class="muted" style="font-weight:400">'+esc(String(res.page_count))+' in the store, newest first</span></h2>';
    for(var pi=0;pi<pgs.length;pi++){ var pg=pgs[pi];
      var plink='/review?path='+enc(hp)+'&file='+enc(hp+'/'+(pg.path||''));
      s+='<div class="brainhit"><div class="bh1"><a href="'+esc(plink)+'" target="_blank">'+esc(pg.title||pg.slug)+'</a>'
        +'<span class="chipm">'+esc(pg.type||'')+'</span>'
        +'<span class="ts mono" style="margin-left:auto;font-size:11px" title="'+esc(pg.path||'')+'">'+esc(pg.slug)+' \u00b7 '+esc(fmtTime(pg.mtime))+' \u00b7 '+esc(String(Math.round((pg.size||0)/102.4)/10))+' KB</span></div></div>';
    }
  }
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
  // Client-side appearance (accent palette + background) lives here rather
  // than in the page header - the header keeps only the theme toggle.
  {id:'appearance', title:'Appearance', keys:[]},
  {id:'runtime', title:'Runtime', keys:['flow','promote','backend']},
  {id:'models', title:'Models', keys:['crew-harness','model','effort','codereview-agent','codereview-model','codereview-effort','qa-agent','qa-model','qa-effort','gate-agent','gate-model','gate-effort']},
  {id:'parallelism', title:'Parallelism', keys:['room-parallel']},
  {id:'learning', title:'Learning', keys:['learn-every','curate-every']},
  {id:'remote', title:'Remote', keys:['remote-mirror','remote-poll-interval','slack-channel','slack-captain-id']},
  {id:'identity', title:'Identity', keys:['captain']}
];
// Browser-local appearance controls (palette cycle + background dialog);
// the ids keep their existing click delegation and label sync.
function appearancePanel(){
  var p=currentPalette();
  return '<div class="cfg-field"><div class="fname">Accent palette'
    +'<div class="fdesc">Cycle the accent: cyan, teal, navy. Applies instantly, stored in this browser.</div></div>'
    +'<div class="cfg-val"><button id="palette-btn" class="btn sm" type="button" title="Cycle accent palette: cyan, teal, navy">'+esc(p.charAt(0).toUpperCase()+p.slice(1))+'</button></div></div>'
    +'<div class="cfg-field"><div class="fname">Background'
    +'<div class="fdesc">Custom canvas color or wallpaper; the default follows the theme.</div></div>'
    +'<div class="cfg-val"><button id="bg-btn" class="btn sm" type="button" title="Background: custom canvas color or wallpaper">&#128444;&#65039; Background&hellip;</button></div></div>';
}
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
  else if(chosen.id==='appearance'){ s+=appearancePanel(); }
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
// Mermaid render pass, shared with /review's iframe overlay - reports-mermaid:
// extracted top-level (mermaidPass, dashboard.ts, alongside readerCss) and
// interpolated here verbatim, the same toString() sharing readerCss itself
// established, so a report's mermaid fence renders here the identical way
// it already does on /review - one implementation, not a second hand-copied
// engine. Runs unconditionally every postFrames() tick (cheap: an early
// return before any CDN load when the current DOM has no fence/block left to
// claim) rather than gated to S.viewer, so it reaches every .reader surface
// the SPA renders markdown into - Reports/Records via viewerHtml AND the
// Board family detail's artifact viewer (boardApplyArt calls it directly too,
// since that content lands outside the render/postFrames cycle entirely).
// The data-mmd/data-processed guards mermaidPass carries make this idempotent
// against the poll's DOM-diff, which deliberately never re-diffs a
// data-preserve island (renderPage's morphInto) - a rendered SVG is never
// re-rendered or lost, and a fresh selection's un-rendered fences get caught
// on the same tick that mounts them.
${mermaidPass.toString()}
function postMermaid(){
  // theme:'dark' + a --surface paper (not /review's hardcoded white) - this
  // reader lives inside the dashboard's own live-themeable chrome, unlike the
  // review iframe's standalone document, so the diagram follows suit instead
  // of sitting as a fixed white card in a dark UI.
  mermaidPass(function(){ return import('https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs').then(function(m){ return m.default; }); },
    'dark', 'background:var(--surface);border:1px solid var(--border);border-radius:8px;margin:12px 0;padding:10px;overflow-x:auto');
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
function toggleNav(force){
  var open = typeof force==='boolean' ? force : !document.body.classList.contains('nav-open');
  // The desktop icon-rail collapse and the phone drawer are two different
  // affordances over the same element - opening the drawer always shows full
  // labels, so a collapse toggled on a wide window before resizing down never
  // strands the phone view on icon-only nav.
  if(open) document.body.classList.remove('sb-collapsed');
  document.body.classList.toggle('nav-open', open);
  var b=el('nav-toggle'); if(b) b.setAttribute('aria-expanded', open?'true':'false');
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
  // Terminal toolbar: blur the clicked button so the focus ring never sticks
  // as a phantom highlight after the action.
  var tbtn=t.closest('#tp-fminus,#tp-fplus,#tp-side');
  if(tbtn){
    tbtn.blur();
    if(tbtn.id==='tp-fminus') termFont(-1);
    else if(tbtn.id==='tp-fplus') termFont(1);
    else { var cb=el('collapse-btn'); if(cb) cb.click(); }
    return;
  }
  // Any [data-td-open] control raises the dock IN PLACE - never a route hop;
  // data-td-family / data-td-fleet aim the client at a workspace.
  if((n=t.closest('[data-td-open]'))){
    e.preventDefault(); n.blur();   // the wait chip sits inside a card anchor - never navigate
    var tf=n.getAttribute('data-td-family');
    tdOpenScoped(tf ? '&family='+enc(tf) : (n.hasAttribute('data-td-fleet') ? '&fleet=1' : tdScope));
    return;
  }
  // Dock controls (blur after acting - the focus-ring lesson).
  var tdb=t.closest('#td-fminus,#td-fplus,#td-min,#td-full,#td-close,#td-rail');
  if(tdb){
    tdb.blur();
    if(tdb.id==='td-rail') tdOpen('split');
    else if(tdb.id==='td-min'){ tdMode='hidden'; tdApply(); }
    else if(tdb.id==='td-fminus') tdFont(-0.5);
    else if(tdb.id==='td-fplus') tdFont(0.5);
    else if(tdb.id==='td-full') tdOpen(tdMode==='full'?'split':'full');
    else tdClose();
    return;
  }
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
  if(t.closest('#nav-toggle')){ toggleNav(); return; }
  if(t.closest('#nav-scrim')){ toggleNav(false); return; }
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
  if((n=t.closest('[data-rail-toggle]'))){ railToggle(); return; }             // collapse/expand the detail's left rail
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
  if((n=t.closest('[data-sc-want]'))){ scWanted[n.getAttribute('data-sc-want')]=1; e.preventDefault(); renderPage(); return; }  // available worktree: first open triggers its loads
  if((n=t.closest('[data-repo-pull]'))){ scPullRun(S.route.home?S.route.home.path:'', n.getAttribute('data-repo-pull')); return; }  // fetch + ff-only sync
  if((n=t.closest('[data-gg-pick]'))){ ggPickerOpen(n); return; }               // branch picker: searchable dropdown
  if((n=t.closest('.ggpanel'))){ return; }                                      // clicks inside the picker panel are its own
  if((n=t.closest('.glh'))){ ggFocusLane(n); return; }                          // graph lane: spotlight the branch line
  if((n=t.closest('.ggrow'))){ ggToggleCommit(n); return; }                     // graph row: that commit's diff inline
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
  if(S.route.name==='chat' && S.route.fleet){ // retired route - board + dock instead
    history.replaceState({}, '', '/fleets/'+enc(S.route.fleet)+'/board');
    S.route=parseRoute(location.pathname);
    setTimeout(function(){ if(tdMode==='closed') tdOpen('split'); }, 0);
  }
  if(S.route.name==='config' && !S.cfgSection) S.cfgSection=CFG_SECTIONS[0].id;
  // The standing dock intent applies at BOOT too: boot sets S.route without
  // applyRoute, so the reopen hook there never sees a reload (the retired-chat
  // redirect's own setTimeout precedent; tdMount retries until the home
  // resolves).
  if(tdIntent && tdRouteOk()) setTimeout(function(){ if(tdMode==='closed') tdOpen(tdIntent); }, 0);
  syncViewer(S.route);
  renderNav(); renderHead(); renderPage();
  tdApply(); // boot sets S.route without applyRoute - the pill needs its route pass here too
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
