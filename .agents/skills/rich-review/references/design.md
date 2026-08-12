# Design snippets and layout safety

Use the SUBJECT repo's own design system first (its Tailwind config, tokens,
component library). These pinned CDN snippets are the fallback for a repo that
has none - say which source you used.

## Pinned CDN snippets

```html
<!-- Tailwind (browser build) -->
<script src="https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4/dist/index.global.js"></script>
<!-- DaisyUI on top of Tailwind -->
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/daisyui@5/daisyui.css">
<!-- Mermaid: render fenced diagrams -->
<script type="module">
  import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";
  mermaid.initialize({ startOnLoad: true });
</script>
```

The dashboard whiteboard's own editor runtime pins live in `bin/dashboard.ts`
(`WHITEBOARD_CDN`) - that block is authoritative for Excalidraw versions;
never restate them here.

## Layout safety rules

- The page must read at 1280px AND 900px wide without horizontal scroll; wide
  content (tables, diagrams, code) scrolls inside its own `overflow-x: auto`
  container, the body never does.
- No fixed heights on text containers - clipped text is the #1 review-round
  waster; let content size its box.
- Minimum 13px body text; monospace only for code, ids, and paths.
- Every image and diagram gets `max-width: 100%`.
- Self-contained file: inline styles/scripts or pinned CDN only - a reviewer
  opens the file months later and it must still render.
- Stable element ids on sections and key nodes: review pins anchor by
  selector, and your later edits should not orphan the captain's comments.
