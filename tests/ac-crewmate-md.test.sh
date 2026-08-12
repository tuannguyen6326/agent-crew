#!/usr/bin/env bash
# ac-crewmate-md.test.sh - fleet-wide crewmate instructions and harness
# settings: copied into the worktree's .claude/ (CLAUDE.md, settings.json),
# invisible to git status, and never clobbering a copy the repo ships itself.
# shellcheck disable=SC2016  # script bodies are deliberately unexpanded here

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
repo="$(make_repo)"
printf 'FLEET RULES\n' >"$AC_HOME/CREWMATE.md"

wt="$("$BIN/ac-tree.sh" get --repo "$repo" --id t1 2>/dev/null)"

seed() {
  AC_HOME="$AC_HOME" bash -c "
    set -euo pipefail
    . '$BIN/ac-lib.sh'
    ac_seed_crewmate_md '$1'
  "
}

seed "$wt"
assert_file "$wt/.claude/CLAUDE.md" "instructions copied"
assert_eq "$(cat "$wt/.claude/CLAUDE.md")" "FLEET RULES" "content matches"
assert_eq "$(git -C "$wt" status --porcelain)" "" "copy invisible to git status"

# Idempotent, and a pre-existing (repo-owned) copy wins.
printf 'REPO OWNED\n' >"$wt/.claude/CLAUDE.md"
seed "$wt"
assert_eq "$(cat "$wt/.claude/CLAUDE.md")" "REPO OWNED" "existing copy preserved"

# No CREWMATE.md in the home: quietly does nothing.
rm -f "$AC_HOME/CREWMATE.md" "$wt/.claude/CLAUDE.md"
seed "$wt"
assert_no_file "$wt/.claude/CLAUDE.md" "no source, no copy"

# Container fallback: <container>/.claude/CLAUDE.md is the
# shared source when the fleet has no CREWMATE.md of its own...
mkdir -p "$(dirname "$AC_HOME")/.claude"
printf 'CONTAINER RULES\n' >"$(dirname "$AC_HOME")/.claude/CLAUDE.md"
seed "$wt"
assert_eq "$(cat "$wt/.claude/CLAUDE.md")" "CONTAINER RULES" "container source used"

# ...and when BOTH exist the seed MERGES them - container baseline first,
# fleet-specific layer last (the later, more specific word) - with
# provenance markers only in the merged case.
rm -f "$wt/.claude/CLAUDE.md"
printf 'FLEET RULES\n' >"$AC_HOME/CREWMATE.md"
seed "$wt"
merged="$(cat "$wt/.claude/CLAUDE.md")"
assert_contains "$merged" "CONTAINER RULES" "merged seed keeps the container baseline"
assert_contains "$merged" "FLEET RULES" "merged seed keeps the fleet layer"
assert_contains "$merged" "agent-crew seed: fleet" "merged seed carries provenance markers"
case "$merged" in
  *"CONTAINER RULES"*"FLEET RULES"*) : ;;
  *) fail "container baseline must come before the fleet layer" ;;
esac
assert_eq "$(git -C "$wt" status --porcelain)" "" "merged copy invisible to git status"

# The machine-owned learned layer ($AC_HOME/CREWMATE-learned.md, written only
# by ac-learn.sh transactions) merges as its own labeled layer BETWEEN the
# container baseline and the fleet CREWMATE.md: the captain's hand-written
# layer must read after the machine's, so on any conflict the captain's word
# is the later, more specific one. Absent the file, the seed is byte-identical
# to the two-layer merge above - which the earlier assertions already proved.
rm -f "$wt/.claude/CLAUDE.md"
printf 'LEARNED LESSONS\n' >"$AC_HOME/CREWMATE-learned.md"
seed "$wt"
merged="$(cat "$wt/.claude/CLAUDE.md")"
assert_contains "$merged" "LEARNED LESSONS" "merged seed keeps the learned layer"
assert_contains "$merged" "agent-crew seed: fleet-learned" "learned layer carries its own provenance marker"
case "$merged" in
  *"CONTAINER RULES"*"LEARNED LESSONS"*"FLEET RULES"*) : ;;
  *) fail "layer order must be container -> learned -> fleet" ;;
esac
rm -f "$AC_HOME/CREWMATE-learned.md"

# Fleet harness settings seed into the worktree's .claude/settings.json the
# same way: per-fleet wins over container, a pre-existing file wins over
# both, the copy is a real file (never a symlink - a crewmate's own
# permission grants must stay local), and it stays invisible to git status.
seed_settings() {
  AC_HOME="$AC_HOME" bash -c "
    set -euo pipefail
    . '$BIN/ac-lib.sh'
    ac_seed_crew_settings '$1'
  "
}
printf '{"enabledPlugins":{"container":true}}\n' >"$(dirname "$AC_HOME")/.claude/settings.json"
seed_settings "$wt"
assert_eq "$(cat "$wt/.claude/settings.json")" '{"enabledPlugins":{"container":true}}' "container settings seeded"
[ -L "$wt/.claude/settings.json" ] && fail "settings must be a copy, never a symlink"
assert_eq "$(git -C "$wt" status --porcelain)" "" "settings copy invisible to git status"
rm -f "$wt/.claude/settings.json"
mkdir -p "$AC_HOME/.claude"
printf '{"enabledPlugins":{"fleet":true}}\n' >"$AC_HOME/.claude/settings.json"
seed_settings "$wt"
assert_eq "$(cat "$wt/.claude/settings.json")" '{"enabledPlugins":{"fleet":true}}' "per-fleet settings win over container"
printf '{"repo":true}\n' >"$wt/.claude/settings.json"
seed_settings "$wt"
assert_eq "$(cat "$wt/.claude/settings.json")" '{"repo":true}' "existing settings preserved"
rm -f "$AC_HOME/.claude/settings.json" "$(dirname "$AC_HOME")/.claude/settings.json"

# Crewmate-facing skills are symlinked into the worktree: container source
# wins over the distro checkout, repo-shipped wins over both, links stay
# invisible to git status, and seeding is idempotent.
seed_skills() {
  AC_HOME="$AC_HOME" bash -c "
    set -euo pipefail
    . '$BIN/ac-lib.sh'
    ac_seed_crew_skills '$1' '${2:-}'
  "
}
mkdir -p "$(dirname "$AC_HOME")/.claude/skills/crew-ship"
printf 'CONTAINER SKILL\n' >"$(dirname "$AC_HOME")/.claude/skills/crew-ship/SKILL.md"
seed_skills "$wt"
[ -L "$wt/.claude/skills/crew-ship" ] || fail "skill symlinked"
assert_eq "$(cat "$wt/.claude/skills/crew-ship/SKILL.md")" "CONTAINER SKILL" "container skill wins"
[ -L "$wt/.claude/skills/crew-qa" ] || fail "distro fallback for crew-qa"
[ -f "$wt/.claude/skills/crew-qa/SKILL.md" ] || fail "distro crew-qa link resolves"
[ -L "$wt/.claude/skills/document" ] || fail "distro fallback for document"
[ -f "$wt/.claude/skills/document/SKILL.md" ] || fail "distro document link resolves"
assert_eq "$(git -C "$wt" status --porcelain)" "" "skill links invisible to git status"
seed_skills "$wt"
assert_eq "$(git -C "$wt" status --porcelain)" "" "idempotent"

# ONLY crew-ship, qa, and document are crewmate-facing: captain/crewchief
# skills (rich-review, bearings, debrief) must never land in a crew worktree.
for extra in rich-review bearings debrief; do
  if [ -e "$wt/.claude/skills/$extra" ]; then
    fail "$extra must not be seeded into crew worktrees"
  fi
done
seeded="$(cd "$wt/.claude/skills" && printf '%s\n' * | sort | tr '\n' ' ')"
assert_eq "$seeded" "crew-qa crew-ship document " "exactly crew-ship + crew-qa + document seeded"
# ^ Empty learned stores are a no-op (byte-identical to today): the seeded set
#   is exactly the three built-ins while $AC_HOME/skills and the container carry
#   no origin: learned skills. The learned-skill tests below all run AFTER this.

# --- ac_skills_dir: the per-fleet learned-skill store resolver -----------------
# Mirrors ac_state_dir / ac_data_dir: returns $AC_HOME/skills and creates it.
rm -rf "$AC_HOME/skills"
skills_dir="$(AC_HOME="$AC_HOME" bash -c ". '$BIN/ac-lib.sh'; ac_skills_dir")"
assert_eq "$skills_dir" "$AC_HOME/skills" "ac_skills_dir returns \$AC_HOME/skills"
[ -d "$AC_HOME/skills" ] || fail "ac_skills_dir creates the store"

# --- learned-skill seeding: fleet store only -----------------------------------
# Fleet-learned: a skill in $AC_HOME/skills/<name> is symlinked in + info/excluded.
mkdir -p "$AC_HOME/skills/foo"
printf -- '---\norigin: learned\n---\nFLEET FOO\n' >"$AC_HOME/skills/foo/SKILL.md"
# Legacy container-learned state is a migration input and is not seeded.
mkdir -p "$(dirname "$AC_HOME")/.claude/skills/bar"
printf -- '---\norigin: learned\n---\nPROMOTED BAR\n' >"$(dirname "$AC_HOME")/.claude/skills/bar/SKILL.md"
# A plain container skill outside the built-in allowlist is also not seeded.
mkdir -p "$(dirname "$AC_HOME")/.claude/skills/rich-review"
printf 'PLAIN RICH-REVIEW\n' >"$(dirname "$AC_HOME")/.claude/skills/rich-review/SKILL.md"
seed_skills "$wt"
[ -L "$wt/.claude/skills/foo" ] || fail "fleet-learned foo symlinked"
assert_contains "$(cat "$wt/.claude/skills/foo/SKILL.md")" "FLEET FOO" "fleet-learned foo resolves"
assert_no_file "$wt/.claude/skills/bar" "legacy container-learned bar is not seeded before migration"
[ -e "$wt/.claude/skills/rich-review" ] && fail "container skill without origin: learned must not be seeded"
assert_eq "$(git -C "$wt" status --porcelain)" "" "learned skill links invisible to git status"

# No built-in shadowing: a learned skill named crew-ship does NOT replace the
# built-in link - loop 1 claims the name first and the dst-exists guard skips it.
mkdir -p "$AC_HOME/skills/crew-ship"
printf -- '---\norigin: learned\n---\nLEARNED SHIP\n' >"$AC_HOME/skills/crew-ship/SKILL.md"
seed_skills "$wt"
assert_eq "$(cat "$wt/.claude/skills/crew-ship/SKILL.md")" "CONTAINER SKILL" "built-in crew-ship wins over a learned crew-ship"

# Fleet-local ownership wins even when a legacy container copy shares the name.
mkdir -p "$(dirname "$AC_HOME")/.claude/skills/dup"
printf -- '---\norigin: learned\n---\nCONTAINER DUP\n' >"$(dirname "$AC_HOME")/.claude/skills/dup/SKILL.md"
mkdir -p "$AC_HOME/skills/dup"
printf -- '---\norigin: learned\n---\nFLEET DUP\n' >"$AC_HOME/skills/dup/SKILL.md"
seed_skills "$wt"
[ -L "$wt/.claude/skills/dup" ] || fail "dup symlinked"
assert_contains "$(cat "$wt/.claude/skills/dup/SKILL.md")" "FLEET DUP" "fleet-local wins over a legacy container copy"

# --- seeding-is-use telemetry: a NEW fleet-learned symlink stamps the source
# folder's .usage.meta (class 2 only, never class-1 built-ins) ------------------
# Self-contained: fresh skills + a fresh worktree, so the counts are exact.
tel_wt="$TMP/wt-tel"; git init -q "$tel_wt"
usage_meta_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1; }
mkdir -p "$AC_HOME/skills/telfleet"
printf -- '---\norigin: learned\n---\nTEL FLEET\n' >"$AC_HOME/skills/telfleet/SKILL.md"
mkdir -p "$(dirname "$AC_HOME")/.claude/skills/telcont"
printf -- '---\norigin: learned\n---\nTEL CONT\n' >"$(dirname "$AC_HOME")/.claude/skills/telcont/SKILL.md"
seed_skills "$tel_wt"
assert_eq "$(usage_meta_get "$AC_HOME/skills/telfleet/.usage.meta" seeded_count)" "1" "fleet-learned (class 2) seed stamps seeded_count=1"
[ -n "$(usage_meta_get "$AC_HOME/skills/telfleet/.usage.meta" last_seeded)" ] || fail "fleet-learned seed stamps last_seeded"
assert_no_file "$(dirname "$AC_HOME")/.claude/skills/telcont/.usage.meta" "legacy container learned skill is not seeded or stamped"
# Class-1 built-ins (crew-ship, resolved from the container copy here) never get telemetry.
assert_no_file "$(dirname "$AC_HOME")/.claude/skills/crew-ship/.usage.meta" "class-1 built-in gets no .usage.meta"

# A NEW symlink bumps; re-seeding an already-linked worktree does NOT (dst-exists skip).
seed_skills "$tel_wt"
assert_eq "$(usage_meta_get "$AC_HOME/skills/telfleet/.usage.meta" seeded_count)" "1" "idempotent re-seed does NOT re-bump (no new symlink)"
tel_wt2="$TMP/wt-tel2"; git init -q "$tel_wt2"
seed_skills "$tel_wt2"
assert_eq "$(usage_meta_get "$AC_HOME/skills/telfleet/.usage.meta" seeded_count)" "2" "a NEW worktree's symlink bumps seeded_count to 2"

# The consolidate archive subdir is skipped by class 2: never seeded, never stamped.
arch_wt="$TMP/wt-arch"; git init -q "$arch_wt"
mkdir -p "$AC_HOME/skills/skills-archive/retired"
printf -- '---\norigin: learned\n---\nRETIRED\n' >"$AC_HOME/skills/skills-archive/retired/SKILL.md"
seed_skills "$arch_wt"
assert_no_file "$arch_wt/.claude/skills/skills-archive" "the skills-archive subdir is never seeded as a skill"
assert_no_file "$AC_HOME/skills/skills-archive/.usage.meta" "the skills-archive subdir is never stamped"

# --- info/exclude must name the path GIT SEES --------------------------------
# This distro ships .claude/skills as a TRACKED SYMLINK -> ../.agents/skills,
# and git never traverses a symlink: an entry at the symlink path matches
# nothing, so every seeded link showed as untracked dirt at the REAL path.
# Assert on git's own behavior (status / check-ignore), never on the exclude
# text alone - the whole bug was an entry that looked right and matched nothing.
excl_of() { git -C "$1" rev-parse --path-format=absolute --git-path info/exclude; }

# Real .claude/skills (every ordinary project repo): the entry is unchanged.
grep -qxF '/.claude/skills/crew-ship' "$(excl_of "$wt")" \
  || fail "real .claude/skills keeps the /.claude/skills/<name> entry"

sym_wt="$TMP/wt-sym"
git init -q -b main "$sym_wt"
git -C "$sym_wt" config user.email test@test
git -C "$sym_wt" config user.name test
mkdir -p "$sym_wt/.agents/skills" "$sym_wt/.claude"
(cd "$sym_wt/.claude" && ln -s ../.agents/skills skills)
git -C "$sym_wt" add .claude/skills
git -C "$sym_wt" commit -qm init
seed_skills "$sym_wt"
[ -L "$sym_wt/.agents/skills/crew-ship" ] || fail "seeded link lands at the resolved path"
grep -qxF '/.agents/skills/crew-ship' "$(excl_of "$sym_wt")" \
  || fail "symlinked .claude/skills: exclude entry written at the resolved path"
git -C "$sym_wt" check-ignore -q .agents/skills/crew-ship \
  || fail "git must actually ignore the seeded link"
assert_eq "$(git -C "$sym_wt" status --porcelain)" "" "symlinked .claude/skills: worktree clean after seed"

# Self-heal on re-seed: the pool REUSES worktrees and the loops skip a name
# already linked, so the exclude ensure must NOT be gated on a NEW symlink.
# Replacing the entries with the old useless ones reproduces an already-seeded
# worktree that predates this fix.
printf '/.claude/skills/crew-ship\n' >"$(excl_of "$sym_wt")"
seed_skills "$sym_wt"
assert_eq "$(git -C "$sym_wt" status --porcelain)" "" "re-seed self-heals an already-seeded worktree"
assert_eq "$(grep -cxF '/.agents/skills/crew-ship' "$(excl_of "$sym_wt")" || true)" "1" \
  "the healed entry is not duplicated"

# Self-heal covers the links THE SEED OWNS, never every name in the loop: a
# repo-shipped skill's dst is a REAL, TRACKED directory, and excluding it would
# swallow every file later added to that package - repo-wide and unversioned.
ship_wt="$TMP/wt-shipped"
git init -q -b main "$ship_wt"
git -C "$ship_wt" config user.email test@test
git -C "$ship_wt" config user.name test
mkdir -p "$ship_wt/.agents/skills/crew-ship" "$ship_wt/.claude"
printf 'REPO SHIPPED\n' >"$ship_wt/.agents/skills/crew-ship/SKILL.md"
(cd "$ship_wt/.claude" && ln -s ../.agents/skills skills)
git -C "$ship_wt" add .claude/skills .agents/skills/crew-ship/SKILL.md
git -C "$ship_wt" commit -qm init
seed_skills "$ship_wt"
[ -L "$ship_wt/.agents/skills/crew-ship" ] && fail "repo-shipped crew-ship must not be replaced by a seeded link"
grep -qxF '/.agents/skills/crew-ship' "$(excl_of "$ship_wt")" \
  && fail "a repo-shipped (tracked) skill must never get an exclude entry"
printf 'NEW\n' >"$ship_wt/.agents/skills/crew-ship/references.md"
assert_eq "$(git -C "$ship_wt" status --porcelain)" "?? .agents/skills/crew-ship/references.md" \
  "a file added to a repo-shipped skill stays visible to git"

# --- dangling-link repair: a retired fleet-learned skill's symlink must not
# outlive its source ------------------------------------------------------
# Pool slots are REUSED, not deleted (AGENTS.md section 6), so a symlink to a
# skill later retired from $AC_HOME/skills survives every return/get cycle
# forever unless the seed itself repairs it on the next call. `-e` alone
# cannot prove the repair: it already reports false for a dangling symlink,
# so the assertion checks `-L` directly - the whole bug is a link that looks
# absent to `-e` and is not.
dangle_wt="$TMP/wt-dangle"; git init -q "$dangle_wt"
mkdir -p "$AC_HOME/skills/retiring"
printf -- '---\norigin: learned\n---\nRETIRING\n' >"$AC_HOME/skills/retiring/SKILL.md"
seed_skills "$dangle_wt"
[ -L "$dangle_wt/.claude/skills/retiring" ] || fail "setup: retiring skill must be linked before retirement"
rm -rf "$AC_HOME/skills/retiring"
[ -L "$dangle_wt/.claude/skills/retiring" ] || fail "setup: link must survive the source removal"
[ -e "$dangle_wt/.claude/skills/retiring" ] && fail "setup: link must be dangling, not resolving"
seed_skills "$dangle_wt"
[ -L "$dangle_wt/.claude/skills/retiring" ] && fail "re-seed must repair the dangling retired-skill link"
assert_eq "$(git -C "$dangle_wt" status --porcelain)" "" "repaired dangling link leaves no git dirt"

# --- per-harness DESTINATION: codex scans .agents/skills, never .claude/skills -
# Verified 2026-07-31 with two local renderers, no API call (repo-knowledge
# multica-research): codex-cli sees .agents/skills ONLY; claude sees
# .claude/skills ONLY. A codex crewmate seeded at the old hardcoded
# .claude/skills target receives ZERO fleet skills (not zero skills overall -
# it still sees its system/user/plugin roots - only the fleet layer is
# missing). A throwaway repo (never agent-crew's own checkout, which ships
# .claude/skills as a tracked symlink to ../.agents/skills and would mask
# this) is required to prove it.
codex_wt="$(make_repo wt-codex)"
seed_skills "$codex_wt" codex
[ -L "$codex_wt/.agents/skills/crew-ship" ] || fail "codex crewmate must see the fleet skill layer at .agents/skills"
assert_no_file "$codex_wt/.claude/skills" "codex seed never touches .claude/skills (codex cannot see it)"
grep -qxF '/.agents/skills/crew-ship' "$(excl_of "$codex_wt")" \
  || fail "codex seed's exclude entry names the path git sees"
assert_eq "$(git -C "$codex_wt" status --porcelain)" "" "codex seed invisible to git status"

# claude (default/explicit) is unaffected: still .claude/skills, never .agents/skills.
claude_wt="$(make_repo wt-claude-explicit)"
seed_skills "$claude_wt" claude
[ -L "$claude_wt/.claude/skills/crew-ship" ] || fail "an explicit claude harness keeps the .claude/skills target"
assert_no_file "$claude_wt/.agents/skills" "claude seed never touches .agents/skills"

# --- the FINDING-AUTHORITY rule reaches the agents who actually write findings -
# The rule is authored on four surfaces, but this is the only one the crewmates
# READ: AGENTS.md is the crewchief's file, and a rule that never reaches the
# author binds nobody. Assert on the SHIPPED starter travelling the real seed
# path, so the mandate and what lands in a worktree cannot drift apart.
root="$(cd "$BIN/.." && pwd -P)"
rm -f "$(dirname "$AC_HOME")/.claude/CLAUDE.md"
cp "$root/docs/examples/CREWMATE.md" "$AC_HOME/CREWMATE.md"
rule_wt="$TMP/wt-rule"; git init -q "$rule_wt"
seed "$rule_wt"
seeded_md="$(cat "$rule_wt/.claude/CLAUDE.md")"
assert_contains "$seeded_md" "names the authority for its EXPECTED behavior" \
  "the seeded instructions state the finding-authority rule"
assert_contains "$seeded_md" "OUTSIDE this repository" "clause (a) names the out-of-repo actor"
assert_contains "$seeded_md" "never as a defect" "clause (a) names the fallback"
assert_contains "$seeded_md" "holds everything constant except the disputed variable" \
  "clause (b) is stated"
assert_contains "$seeded_md" "authority_class" "the wire key authority_class is named"
assert_contains "$seeded_md" '`authority`: one sentence naming WHO' "the wire key authority is named"
assert_contains "$seeded_md" 'DOWNGRADED to `ask-user`' "the seeded rule names the consequence"

# --- the 0-FIX-FREEZE law travels the same seed path -------------------------
# Same reasoning, same surface: the crewmate that would polish an advisory
# after a PASS verdict is the one that has to read the law forbidding it. The
# runner's guard (bin/ac-ship.sh) refuses the round, but a refusal the crewmate
# was never told to expect reads as a broken tool.
assert_contains "$seeded_md" "FREEZES the tree" "the seeded instructions state the 0-fix-freeze law"
assert_contains "$seeded_md" "never a licence to commit" "the law names what an advisory is NOT"
assert_contains "$seeded_md" "follow-up task" "the law names the remedy for an advisory worth fixing"

# --- the seed targets the file the SPAWNED HARNESS actually reads --------------
# codex loads <worktree>/AGENTS.md and NOTHING else at session start (verified
# against codex-cli 0.144.6 with `codex debug prompt-input`: with AGENTS.md,
# .claude/CLAUDE.md and root CLAUDE.md all present carrying distinct tokens,
# only the AGENTS.md token reached the model-visible prompt; a nested
# .claude/AGENTS.md, .codex/AGENTS.md or sub/AGENTS.md was loaded neither
# additively nor as a fallback). So seeding only .claude/CLAUDE.md left every
# codex crewmate - crew-dispatch routes the whole code-review stage to one -
# without the fleet layer it is judged by.
seed_h() {
  AC_HOME="$AC_HOME" bash -c "
    set -euo pipefail
    . '$BIN/ac-lib.sh'
    ac_seed_crewmate_md '$1' '$2'
  "
}
mkdir -p "$(dirname "$AC_HOME")/.claude"
printf 'CONTAINER RULES\n' >"$(dirname "$AC_HOME")/.claude/CLAUDE.md"
printf 'FLEET RULES\n' >"$AC_HOME/CREWMATE.md"

cx_wt="$TMP/wt-codex"; git init -q "$cx_wt"
seed_h "$cx_wt" codex
assert_file "$cx_wt/AGENTS.md" "codex target seeded where codex reads it"
assert_no_file "$cx_wt/.claude/CLAUDE.md" "codex target does not also write the claude file"
cx_md="$(cat "$cx_wt/AGENTS.md")"
assert_contains "$cx_md" "CONTAINER RULES" "codex seed carries the container baseline"
assert_contains "$cx_md" "FLEET RULES" "codex seed carries the fleet layer"
case "$cx_md" in
  *"CONTAINER RULES"*"FLEET RULES"*) : ;;
  *) fail "codex seed: container baseline must come before the fleet layer" ;;
esac
assert_eq "$(git -C "$cx_wt" status --porcelain)" "" "codex seed invisible to git status"
grep -qxF '/AGENTS.md' "$(excl_of "$cx_wt")" \
  || fail "codex seed excluded at the path git sees"

# ...and in the shape the seed ACTUALLY runs in: a POOLED worktree, which is a
# LINKED one. A linked worktree's info/exclude IS the main repo's file (git
# resolves --git-path info/exclude to the common dir - verified), so the entry
# reaches every worktree of that repo and outlives the lease. That is the same
# repo-wide reach the /.claude/CLAUDE.md entry has always had, and it is why
# the entry is only ever written when the repo ships NO AGENTS.md of its own.
pool_wt="$("$BIN/ac-tree.sh" get --repo "$repo" --id t-codex 2>/dev/null)"
seed_h "$pool_wt" codex
assert_file "$pool_wt/AGENTS.md" "codex seed lands in a pooled (linked) worktree"
assert_eq "$(git -C "$pool_wt" status --porcelain)" "" "codex seed invisible to git status in a pooled worktree"
git -C "$pool_wt" check-ignore -q AGENTS.md \
  || fail "git must actually ignore the seeded AGENTS.md in a pooled worktree"
assert_eq "$(git -C "$repo" rev-parse --path-format=absolute --git-path info/exclude)" \
          "$(excl_of "$pool_wt")" \
  "a linked worktree shares the main repo's info/exclude - the entry is repo-wide"

# opencode takes the SAME AGENTS.md target codex takes: on 2026-07-27 a
# live-pane probe verified it on opencode 1.18.5 - opencode loads AGENTS.md and
# does NOT load .claude/CLAUDE.md (harness-operations
# references/harness-facts.md, opencode "Instruction files"). Everything else -
# no harness (every pre-existing caller) and an explicit claude - is UNCHANGED
# and still produces the SAME file at the SAME path, byte for byte. What these
# assertions pin is WHICH PATH the layer lands at per harness: mere existence
# would pass whether the layer reached the file the harness reads or the one it
# ignores, which is exactly the defect this covers.
def_wt="$TMP/wt-default"; git init -q "$def_wt"; seed "$def_wt"
cl_wt="$TMP/wt-claude"; git init -q "$cl_wt"; seed_h "$cl_wt" claude
oc_wt="$TMP/wt-opencode"; git init -q "$oc_wt"; seed_h "$oc_wt" opencode
cmp -s "$def_wt/.claude/CLAUDE.md" "$cl_wt/.claude/CLAUDE.md" \
  || fail "an explicit claude harness must be byte-identical to no harness at all"
assert_file "$oc_wt/AGENTS.md" "opencode target seeded where opencode reads it"
assert_no_file "$oc_wt/.claude/CLAUDE.md" "opencode target does not also write the claude file"
cmp -s "$cx_wt/AGENTS.md" "$oc_wt/AGENTS.md" \
  || fail "opencode must produce the same layer the codex path produces"
grep -qxF '/AGENTS.md' "$(excl_of "$oc_wt")" \
  || fail "opencode seed excluded at the path git sees"
grep -qxF '/.claude/CLAUDE.md' "$(excl_of "$cl_wt")" \
  || fail "the claude target keeps its own exclude entry"
assert_no_file "$cl_wt/AGENTS.md" "the claude target never writes AGENTS.md"
assert_no_file "$def_wt/AGENTS.md" "the no-harness default never writes AGENTS.md"

# A repo-shipped AGENTS.md is the repo's own law and is NEVER clobbered - the
# same repo-shipped-wins early return that protects a repo-shipped CLAUDE.md.
# It gets no exclude entry either: AGENTS.md is TRACKED here (this distro ships
# one), and info/exclude cannot hide a tracked file anyway - excluding the path
# would only swallow it if the repo ever untracked it.
law_wt="$TMP/wt-shipped-agents"
git init -q -b main "$law_wt"
git -C "$law_wt" config user.email test@test
git -C "$law_wt" config user.name test
printf 'REPO SHIPPED LAW\n' >"$law_wt/AGENTS.md"
git -C "$law_wt" add AGENTS.md
git -C "$law_wt" commit -qm init
seed_h "$law_wt" codex
assert_eq "$(cat "$law_wt/AGENTS.md")" "REPO SHIPPED LAW" "a repo-shipped AGENTS.md is never clobbered"
assert_eq "$(git -C "$law_wt" status --porcelain)" "" "a repo-shipped AGENTS.md stays unmodified"
grep -qxF '/AGENTS.md' "$(excl_of "$law_wt")" \
  && fail "a repo-shipped (tracked) AGENTS.md must never get an exclude entry"

# --- ac-spawn.sh threads its RESOLVED harness into the seed --------------------
# The function above is only half of it: a seed that CAN target AGENTS.md but is
# never told which harness is spawning still leaves every codex crewmate on the
# claude file. ac-spawn.sh resolves the harness before it leases the worktree,
# so the seed target is decided from the SAME value the launch line is built
# from - one resolution, never two that can drift.
make_fake_herdr
export AC_SPAWN_SETTLE=0
# Every pane here clears the composer-ready observation (bin/ac-spawn.sh
# kickoff_wait_input_ready) immediately - this suite is not testing that gate
# (tests/ac-spawn-kickoff-ready.test.sh owns it), it just needs its spawns to
# complete without a real harness's boot delay.
: >"$FAKE_HERDR/.pane-idle-by-default"
export AC_KICKOFF_READY_BUDGET=5
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/stubbin/codex"
chmod +x "$TMP/stubbin/codex"
spawn_repo="$(make_repo spawnproj)"
"$BIN/ac-brief.sh" sx1 spawnproj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" sx1 "$spawn_repo" --harness codex --mode local-only >/dev/null 2>&1
sx_wt="$(bash -c ". '$BIN/ac-lib.sh'; ac_meta_get '$AC_HOME/state/sx1.meta' worktree")"
[ -n "$sx_wt" ] || fail "the codex spawn recorded no worktree"
assert_file "$sx_wt/AGENTS.md" "a codex SPAWN seeds the file codex reads"
assert_no_file "$sx_wt/.claude/CLAUDE.md" "a codex spawn does not seed the claude file"
assert_contains "$(cat "$sx_wt/AGENTS.md")" "FLEET RULES" "the spawned codex worktree carries the fleet layer"
assert_eq "$(git -C "$sx_wt" status --porcelain)" "" "the spawned codex seed is invisible to git status"

# --- the fleet layer still reaches a crewmate whose repo ships its own file ----
# Repo-shipped-wins protects the repo's own instruction file, but it used to be
# SILENT - indistinguishable from a seed that landed. codex reads AGENTS.md and
# NOTHING else, so no sidecar the LOADER would pick up exists (harness-facts.md
# codex "Instruction files"); the layer travels the kickoff prompt instead, and
# the seed reports the worktree-relative path that prompt must point at.
fb_wt="$TMP/wt-fallback"
git init -q -b main "$fb_wt"
git -C "$fb_wt" config user.email test@test
git -C "$fb_wt" config user.name test
printf 'REPO SHIPPED LAW\n' >"$fb_wt/AGENTS.md"
git -C "$fb_wt" add AGENTS.md
git -C "$fb_wt" commit -qm init
fb_rel="$(seed_h "$fb_wt" codex)"
assert_eq "$fb_rel" ".claude/CREWMATE.md" "the seed reports where the fleet layer landed instead"
assert_eq "$(cat "$fb_wt/AGENTS.md")" "REPO SHIPPED LAW" "the shipped law is still never clobbered"
fb_md="$(cat "$fb_wt/$fb_rel")"
case "$fb_md" in
  *"CONTAINER RULES"*"FLEET RULES"*) : ;;
  *) fail "the fallback carries both sources in the container-then-fleet order" ;;
esac
assert_eq "$(git -C "$fb_wt" status --porcelain)" "" "the fallback and its stamp are invisible to git status"

# A repo shipping NO instruction file is unchanged: the layer reaches the file
# the harness reads, and there is no fallback and nothing to tell the caller.
nf_wt="$TMP/wt-nofile"; git init -q "$nf_wt"
assert_eq "$(seed_h "$nf_wt" codex)" "" "no shipped file, nothing to report"
assert_no_file "$nf_wt/.claude/CREWMATE.md" "no shipped file, no fallback"
cmp -s "$nf_wt/AGENTS.md" "$cx_wt/AGENTS.md" \
  || fail "a repo shipping no instruction file is seeded byte-identically to before"

# --- the seed self-invalidates when its SOURCE changes -------------------------
# A pool worktree keeps the copy it got at lease time, and `ac-tree.sh return`
# does NOT drop it: reset_worktree cleans with `git clean -fdq` (no -x) and the
# seeded file is info/excluded, i.e. IGNORED, so the next lease's early return
# skipped re-seeding and the stale copy outlived every lease of that slot.
st_wt="$TMP/wt-stamp"; git init -q "$st_wt"
seed "$st_wt"
printf 'FLEET RULES v2\n' >"$AC_HOME/CREWMATE.md"
seed "$st_wt"
assert_contains "$(cat "$st_wt/.claude/CLAUDE.md")" "FLEET RULES v2" \
  "a changed seed source refreshes the file the seed itself wrote"

# ...but ONLY a file the seed itself wrote. Anything else at that path - the
# repo's own, or one the crewmate authored mid-lease - is never overwritten.
printf 'CREWMATE AUTHORED\n' >"$st_wt/.claude/CLAUDE.md"
printf 'FLEET RULES v3\n' >"$AC_HOME/CREWMATE.md"
assert_eq "$(seed "$st_wt")" ".claude/CREWMATE.md" "an unowned seeded path routes the layer to the fallback"
assert_eq "$(cat "$st_wt/.claude/CLAUDE.md")" "CREWMATE AUTHORED" \
  "the refresh never overwrites a file the seed did not write"
assert_eq "$(git -C "$st_wt" status --porcelain)" "" "the stamp is invisible to git status"

# The settings seed rides the SAME stamp - one mechanism, not two. A crewmate
# answering "always allow" writes exactly this file, so that grant is what the
# no-clobber half protects here.
mkdir -p "$AC_HOME/.claude"
printf '{"v":1}\n' >"$AC_HOME/.claude/settings.json"
seed_settings "$st_wt"
printf '{"v":2}\n' >"$AC_HOME/.claude/settings.json"
seed_settings "$st_wt"
assert_eq "$(cat "$st_wt/.claude/settings.json")" '{"v":2}' "changed fleet settings refresh the seeded copy"
printf '{"granted":true}\n' >"$st_wt/.claude/settings.json"
printf '{"v":3}\n' >"$AC_HOME/.claude/settings.json"
seed_settings "$st_wt"
assert_eq "$(cat "$st_wt/.claude/settings.json")" '{"granted":true}' \
  "a crewmate's own grants are never overwritten by the refresh"
rm -f "$AC_HOME/.claude/settings.json"

# --- ac-spawn.sh carries the fallback into the kickoff prompt, and only then ---
law_repo="$(make_repo lawproj)"
printf 'REPO SHIPPED LAW\n' >"$law_repo/AGENTS.md"
git -C "$law_repo" add AGENTS.md
git -C "$law_repo" commit -qm law
"$BIN/ac-brief.sh" sx2 lawproj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" sx2 "$law_repo" --harness codex --mode local-only >/dev/null 2>&1
assert_contains "$(cat "$(fake_pane_buf sx2)")" ".claude/CREWMATE.md" \
  "a shipped-law repo's crewmate is pointed at the fleet layer"
case "$(cat "$(fake_pane_buf sx1)")" in
  *CREWMATE.md*) fail "a repo shipping no instruction file gets no extra prompt clause" ;;
esac

# --- the THIRD seed layer: container -> fleet -> crewdomain (R11) ------------
# A crewmate a domainchief spawns must get the domain instruction layer, and it
# reads LAST because the most specific word wins. The layer is gated on the
# SPAWNING session's AC_DOMAIN, so nothing outside a domain changes.

seed_dom() {  # seed_dom <domain> <worktree>
  AC_HOME="$AC_HOME" AC_DOMAIN="$1" bash -c "
    set -euo pipefail
    . '$BIN/ac-lib.sh'
    ac_seed_crewmate_md '$2'
  "
}

l3repo="$(make_repo l3repo)"
l3wt="$("$BIN/ac-tree.sh" get --repo "$l3repo" --id l3 2>/dev/null)"
mkdir -p "$AC_HOME/crewdomains/payments" "$(dirname "$AC_HOME")/.claude"
printf 'CONTAINER RULES\n' >"$(dirname "$AC_HOME")/.claude/CLAUDE.md"
printf 'FLEET RULES\n' >"$AC_HOME/CREWMATE.md"
printf 'DOMAIN RULES\n' >"$AC_HOME/crewdomains/payments/CREWMATE.md"

# AC-11.1 - all three layers, IN ORDER, in the file the harness actually reads.
# Order is asserted by position, not by presence: a layer that lands first
# would be overridden by the ones after it, which is the whole point.
seed_dom payments "$l3wt"
l3out="$(cat "$l3wt/.claude/CLAUDE.md")"
for layer in 'CONTAINER RULES' 'FLEET RULES' 'DOMAIN RULES'; do
  assert_contains "$l3out" "$layer" "AC-11.1: the seeded file carries the $layer layer"
done
assert_eq "$(printf '%s\n' "$l3out" | grep -n 'CONTAINER RULES\|FLEET RULES\|DOMAIN RULES' | cut -d: -f2 | tr '\n' ' ')" \
  "CONTAINER RULES FLEET RULES DOMAIN RULES " \
  "AC-11.1: container first, fleet second, crewdomain LAST - the most specific word reads last"

# AC-11.2 - no domain, exactly today's two layers. The regression guard for
# every ordinary crewmate in the fleet.
l2wt="$("$BIN/ac-tree.sh" get --repo "$l3repo" --id l2 2>/dev/null)"
seed "$l2wt"
l2out="$(cat "$l2wt/.claude/CLAUDE.md")"
case "$l2out" in *'DOMAIN RULES'*) fail "AC-11.2: a crewmate outside a domain must not get the domain layer" ;; esac
assert_contains "$l2out" "CONTAINER RULES" "AC-11.2: and still gets the container layer"
assert_contains "$l2out" "FLEET RULES" "AC-11.2: and the fleet layer"

# A SINGLE available layer is still copied byte-identical, with no markers -
# the rule that keeps a one-source fleet's file clean, unchanged by the loop.
rm -f "$AC_HOME/CREWMATE.md" "$(dirname "$AC_HOME")/.claude/CLAUDE.md"
onewt="$("$BIN/ac-tree.sh" get --repo "$l3repo" --id l1 2>/dev/null)"
seed_dom payments "$onewt"
assert_eq "$(cat "$onewt/.claude/CLAUDE.md")" "DOMAIN RULES" \
  "a single available layer is copied byte-identical, no markers"

# An AC_DOMAIN naming a domain with no CREWMATE.md is not an error - the layer
# is simply absent (AC-4.2's seed half).
printf 'FLEET RULES\n' >"$AC_HOME/CREWMATE.md"
barewt="$("$BIN/ac-tree.sh" get --repo "$l3repo" --id l0 2>/dev/null)"
seed_dom nosuchdomain "$barewt"
assert_eq "$(cat "$barewt/.claude/CLAUDE.md")" "FLEET RULES" \
  "AC-4.2: an absent domain layer leaves the base behaving exactly as today"

# --- the stamp file must never carry an extension a host formatter/linter
# would select - a bare sha256 hex line stamped as `.claude%settings.json`
# makes a real `prettier --check` exit 2 with a SyntaxError (measured:
# prettier 3.9.6, see the report), and the error reads as a defect in the
# HOST repo since the crew's own bookkeeping is invisible to `git status`.
# Every path the seed writes (AGENTS.md, .claude/CLAUDE.md,
# .claude/CREWMATE.md, .claude/settings.json) must produce a stamp name a
# formatter would never pick up, regardless of the seeded path's OWN
# extension - one mechanism for every current and future seeded path.
shape_wt="$TMP/wt-stamp-shape"; git init -q "$shape_wt"
seed "$shape_wt"
seed_settings "$shape_wt"
shape_dir="$shape_wt/.claude/.ac-seed"
[ -d "$shape_dir" ] || fail "stamp dir must exist after seeding"
lookalike="$(find "$shape_dir" -type f \( -name '*.md' -o -name '*.json' -o -name '*.yml' -o -name '*.yaml' -o -name '*.sh' \))"
[ -z "$lookalike" ] || fail "a stamp keeps a host-parseable extension: $lookalike"

# --- a pre-existing (pre-suffix) legacy stamp is MIGRATED, never left as an
# orphan that keeps breaking a host formatter, and ownership keeps working
# (the seed still refreshes the file when its source moves on) -------------
# Reproduces a REAL pool slot from before this fix: this repo's own worktree
# pool measured exactly this shape at intake (.claude/.ac-seed/.claude%CLAUDE.md
# with no suffix, content a bare sha256 line).
mig_wt="$TMP/wt-migrate"; git init -q "$mig_wt"
mkdir -p "$mig_wt/.claude/.ac-seed"
printf 'FLEET RULES\n' >"$mig_wt/.claude/CLAUDE.md"
legacy_stamp="$mig_wt/.claude/.ac-seed/.claude%CLAUDE.md"
printf '%s\n' "$(shasum -a 256 <"$mig_wt/.claude/CLAUDE.md" | awk '{print $1}')" >"$legacy_stamp"
mig_excl="$(git -C "$mig_wt" rev-parse --path-format=absolute --git-path info/exclude)"
printf '/.claude/CLAUDE.md\n/.claude/.ac-seed/\n' >>"$mig_excl"
rm -f "$(dirname "$AC_HOME")/.claude/CLAUDE.md"
seed "$mig_wt"
assert_no_file "$legacy_stamp" "the pre-suffix legacy stamp is retired, not left as an orphan"
new_stamp="$(find "$mig_wt/.claude/.ac-seed" -type f)"
[ -n "$new_stamp" ] || fail "the migrated stamp must exist under the new name"
case "$new_stamp" in *.md|*.json) fail "the migrated stamp must not keep a host-parseable extension: $new_stamp" ;; esac
assert_eq "$(cat "$mig_wt/.claude/CLAUDE.md")" "FLEET RULES" \
  "migration alone does not rewrite content that already matched"
printf 'FLEET RULES v2\n' >"$AC_HOME/CREWMATE.md"
seed "$mig_wt"
assert_eq "$(cat "$mig_wt/.claude/CLAUDE.md")" "FLEET RULES v2" \
  "a migrated slot keeps refreshing on a later source change - no silent fallback degradation"
assert_eq "$(git -C "$mig_wt" status --porcelain)" "" "the migrated stamp stays invisible to git status"

# --- a legacy stamp that does NOT verify is retired too, not left behind
# under its old, host-parseable-looking name --------------------------------
# The seed still correctly declares the destination foreign (unchanged
# ownership: a file it cannot prove it wrote is never adopted), but the
# legacy stamp is the seed's OWN bookkeeping, not a claim on that file, and a
# stamp that no longer verifies can never authorize a refresh either way - so
# leaving it on disk under the pre-suffix name only recreates the exact
# defect (a bare sha256 line named like a host-parseable file) this fix
# exists to kill.
nover_wt="$TMP/wt-legacy-no-verify"; git init -q "$nover_wt"
mkdir -p "$nover_wt/.claude/.ac-seed"
printf 'FLEET RULES\n' >"$nover_wt/.claude/CLAUDE.md"
nover_legacy="$nover_wt/.claude/.ac-seed/.claude%CLAUDE.md"
printf '%s\n' "$(shasum -a 256 <"$nover_wt/.claude/CLAUDE.md" | awk '{print $1}')" >"$nover_legacy"
nover_excl="$(git -C "$nover_wt" rev-parse --path-format=absolute --git-path info/exclude)"
printf '/.claude/CLAUDE.md\n/.claude/.ac-seed/\n' >>"$nover_excl"
printf 'CREWMATE EDITED AFTER SEEDING\n' >"$nover_wt/.claude/CLAUDE.md"
printf 'FLEET RULES\n' >"$AC_HOME/CREWMATE.md"
seed "$nover_wt"
assert_eq "$(cat "$nover_wt/.claude/CLAUDE.md")" "CREWMATE EDITED AFTER SEEDING" \
  "a destination the seed cannot prove it wrote is still never adopted"
assert_no_file "$nover_legacy" \
  "a non-verifying legacy stamp is retired too, not left as a host-parseable orphan"

pass
