// promote.test.ts - the lib.ts twin src/promote.ts introduced, deliveryModeBlock
// (ac_delivery_mode_block's), held to the per-mode delivery contract it renders:
// every mode's exact bytes with no trailing newline, the argument bytes spliced
// untouched (printf's %s took them as they were), and the empty answer for a
// mode it has no arm for. The CLI contract itself is tests/sh/ac-promote.test.sh's.
import { expect, test } from "bun:test";
import { deliveryModeBlock } from "../../src/lib.ts";

const CREW_SHIP =
  "- Mode crew-ship: run the `crew-ship` skill. Its `ac-ship` engine owns the guarded 8-step delivery pipeline (intent, rebase, review, test, document, lint, push, pr). Hand over only after checks pass and include the PR URL.";
const CLOSES =
  "The PR body covers intent, changes, and verification evidence, and ends with `Closes #<n>` only for the GitHub issue the brief says this task fixes; never put close, fix or resolve before any other `#<n>` - GitHub closes that issue on merge.";

test("deliveryModeBlock renders each mode's contract with the argument bytes untouched, no trailing newline, \"\" for a mode with no arm", () => {
  const rows: [[string, string, string, string], Record<string, string>][] = [
    [
      ["crew/s1", "the recorded target branch", "the recorded integration branch", "delivery preparation"],
      {
        "direct-pr": `- Mode direct-pr: after delivery preparation, push \`crew/s1\` and open a PR against the recorded target branch. ${CLOSES}`,
        "feature-pr":
          "- Mode feature-pr: after delivery preparation, leave `crew/s1` clean and fully committed - it lands onto the feature integration branch `the recorded integration branch` (the chief runs ac-merge-local). Never push or open a PR; publication happens ONCE at the feature ship.",
        "local-only": "- Mode local-only: after delivery preparation, leave `crew/s1` clean and fully committed. Never push or open a PR.",
      },
    ],
    [
      ["crew/t9", "", "", ""],
      {
        "direct-pr": `- Mode direct-pr: after , push \`crew/t9\` and open a PR against . ${CLOSES}`,
        "feature-pr":
          "- Mode feature-pr: after , leave `crew/t9` clean and fully committed - it lands onto the feature integration branch `` (the chief runs ac-merge-local). Never push or open a PR; publication happens ONCE at the feature ship.",
        "local-only": "- Mode local-only: after , leave `crew/t9` clean and fully committed. Never push or open a PR.",
      },
    ],
    [
      ["crew/%s `tick`", "base %d", "integ\\n", "loop with  two  spaces"],
      {
        "direct-pr": `- Mode direct-pr: after loop with  two  spaces, push \`crew/%s \`tick\`\` and open a PR against base %d. ${CLOSES}`,
        "feature-pr":
          "- Mode feature-pr: after loop with  two  spaces, leave `crew/%s `tick`` clean and fully committed - it lands onto the feature integration branch `integ\\n` (the chief runs ac-merge-local). Never push or open a PR; publication happens ONCE at the feature ship.",
        "local-only": "- Mode local-only: after loop with  two  spaces, leave `crew/%s `tick`` clean and fully committed. Never push or open a PR.",
      },
    ],
  ];
  for (const [a, want] of rows) {
    expect([a, deliveryModeBlock("crew-ship", ...a)]).toEqual([a, CREW_SHIP]);
    for (const mode of ["direct-pr", "feature-pr", "local-only"]) expect([mode, a, deliveryModeBlock(mode, ...a)]).toEqual([mode, a, want[mode]]);
    for (const mode of ["bogus", "", "Crew-Ship"]) expect([mode, a, deliveryModeBlock(mode, ...a)]).toEqual([mode, a, ""]);
  }
});
