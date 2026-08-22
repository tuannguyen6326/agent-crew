#!/usr/bin/env bash
# ac-page-lint.test.sh - the page-syntax lint trick: extracts every inline
# <script> block from each fixed page, skips a block whose tag carries a
# src= attribute (nothing to check), runs `bun build --no-bundle` over the
# rest, and reports OK/SYNTAX ERROR per page with the three-way exit code
# (0 clean, 1 a page is broken, 2 usage, 3 tooling could not run).
# Runs against a FIXTURE dashboard (a copy of ac-page-lint.sh in a throwaway
# repo, pointed at a tiny fixture bin/dashboard.ts - never the real
# dashboard/*.ts, which this task must not edit). The fixture serves all 5
# fixed-list paths with one external <script src>, one inline <script>, and
# one inline <script type="module"> per page; PAGE_LINT_TEST_BAD=1 swaps the
# module script's body on "/" for one with a syntax error.
# Fail-closed sourcing: unsourced, errexit is never armed and $AC_HOME is the
# operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

command -v bun >/dev/null 2>&1 || { printf 'SKIP: bun not available\n'; exit 0; }
command -v curl >/dev/null 2>&1 || { printf 'SKIP: curl not available\n'; exit 0; }
command -v perl >/dev/null 2>&1 || { printf 'SKIP: perl not available\n'; exit 0; }

repo="$TMP/pagelintrepo"
mkdir -p "$repo/bin"
cp "$BIN/ac-page-lint.sh" "$repo/bin/ac-page-lint.sh"
chmod +x "$repo/bin/ac-page-lint.sh"

cat >"$repo/bin/dashboard.ts" <<'EOF'
// FIXTURE dashboard for ac-page-lint.test.sh - not the real dashboard.
const args = process.argv.slice(2);
let port = 0;
for (let i = 0; i < args.length; i++) if (args[i] === "--port") port = Number(args[i + 1]);
const bad = process.env.PAGE_LINT_TEST_BAD === "1";

const GOOD_A = "const a = 1; console.log(a);";
const GOOD_B = "export const b = 2;";
const BAD_B = "const b = (\nfunction(){\n";

function page(secondScript: string): string {
  return `<!doctype html><html><head><title>fixture</title></head><body>
<script src="/assets/ext.js">this is not valid js !!! (((</script>
<script>${GOOD_A}</script>
<script type="module">${secondScript}</script>
</body></html>`;
}

const PAGES: Record<string, string> = {
  "/": page(bad ? BAD_B : GOOD_B),
  "/term": page(GOOD_B),
  "/whiteboard": page(GOOD_B),
  "/whiteboard-frame": page(GOOD_B),
  "/review": page(GOOD_B),
};

Bun.serve({
  port,
  fetch(req) {
    const path = new URL(req.url).pathname;
    const html = PAGES[path];
    return html
      ? new Response(html, { headers: { "content-type": "text/html; charset=utf-8" } })
      : new Response("not found", { status: 404 });
  },
});
EOF

lint() { (cd "$repo" && ./bin/ac-page-lint.sh "$@"); }

# --- arg handling ------------------------------------------------------------
lint -h | grep -q 'Usage: ac-page-lint.sh' || fail "-h prints usage"
rc=0; lint bogus >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 2 "an unknown arg exits 2"

# --- a clean run: every fixed page OK, external script never checked --------
out="$(lint 2>&1)"; rc=0; lint >"$TMP/clean.out" 2>&1 || rc=$?
assert_eq "$rc" 0 "a clean fixture dashboard exits 0"
out="$(cat "$TMP/clean.out")"
assert_contains "$out" "OK / (2 scripts)" "root page reports 2 checked scripts (the src= one is skipped)"
assert_contains "$out" "OK /term" "the /term page is checked too"
assert_contains "$out" "OK /whiteboard" "the /whiteboard page is checked too"
assert_contains "$out" "OK /whiteboard-frame" "the /whiteboard-frame page is checked too"
assert_contains "$out" "OK /review" "the /review page is checked too"

# --- a planted syntax error in one page's module script is caught -----------
rc=0; PAGE_LINT_TEST_BAD=1 lint >"$TMP/bad.out" 2>&1 || rc=$?
assert_eq "$rc" 1 "a page with a syntax error exits 1"
out="$(cat "$TMP/bad.out")"
assert_contains "$out" "SYNTAX ERROR / script 2" "names the page and the failing script's index"
assert_contains "$out" "OK /term" "an unaffected page still reports OK - failure is per-page, not global"

# --- tooling could not run: bun missing from PATH ---------------------------
emptybin="$TMP/emptybin"
mkdir -p "$emptybin"
for t in bash sh curl perl mktemp cat grep sed kill sleep seq awk; do
  p="$(command -v "$t" 2>/dev/null)" && ln -sf "$p" "$emptybin/$t"
done
rc=0; (cd "$repo" && PATH="$emptybin" ./bin/ac-page-lint.sh) >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 3 "bun missing from PATH exits 3 (tooling could not run)"

# --- tooling could not run: the dashboard itself fails to start -------------
repo2="$TMP/pagelintrepo-broken"
mkdir -p "$repo2/bin"
cp "$BIN/ac-page-lint.sh" "$repo2/bin/ac-page-lint.sh"
chmod +x "$repo2/bin/ac-page-lint.sh"
printf 'throw new Error("fixture: dashboard intentionally broken");\n' >"$repo2/bin/dashboard.ts"
rc=0; (cd "$repo2" && ./bin/ac-page-lint.sh) >/dev/null 2>&1 || rc=$?
assert_eq "$rc" 3 "a dashboard that fails to start exits 3, not 1"

pass
