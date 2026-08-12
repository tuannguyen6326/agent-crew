# Artifact playbooks

Match every playbook whose trigger fits the artifact you are about to write -
one artifact often combines several (a plan that carries a comparison and a
diagram matches three). Read the matching sections BEFORE writing HTML.

## diagram - map relationships, flows, state, architecture

- Use Mermaid when automatic layout matters more than rich node content; use
  CSS grid, SVG, or positioned HTML when each node needs prose, code, or
  controls; hybrid for large systems - a small overview diagram, then detailed
  module cards below it.
- Lead with the question the diagram answers, not the implementation detail
  that produced it; keep the first visual to the core relationship and put
  dense evidence or file references below.
- Give every meaningful node a stable `id` - review anchors and whiteboard
  scenes correlate by id.

## table - enumerable facts, side by side

- Short cells; explanations belong in prose around the table, never inside it.
- One row per subject, one column per question; if a cell needs a paragraph,
  the content wanted a section, not a table.
- Sort by the column the reader will scan for; say the sort in the caption.

## comparison - options weighed against each other

- Name the axes first (cost, risk, blast radius, reversibility), then the
  options; end with a recommendation and what evidence would change it.
- Symmetric coverage: every option answers every axis, "unknown" spelled out.

## plan - staged work the captain will approve

- Slices in landing order, each with: what ships, how it is verified, what it
  risks; call out the irreversible steps and financial paths LOUDLY - they are
  what the captain-required gate keys on.
- The plan's first screen answers "what changes and why now"; details scroll.

## code - diffs and source excerpts

- Never a bare `<pre>` wall for a diff: mark added/removed lines visually and
  name the file and line range above every hunk.
- Excerpts carry `file:line` captions the reader can jump to; trim to the
  lines the point needs.

## input - collect a decision from the captain

- One native control per question (radio for exclusive choices, checkbox for
  multi), the recommendation pre-selected and labelled as yours.
- Every question carries WHY it is asked and what each answer commits to; the
  review loop's general comment is the free-text channel, keep forms for
  discrete choices.

## slides - a narrative walkthrough

- One idea per screenful; a reader who only reads headings must still get the
  story; end with the ask.
