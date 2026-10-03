# ac_seed_runtime_links, frozen as it left bin/ac-lib.sh when its last bash
# caller (bin/ac-fleet-new.sh) was ported. Sourced after ac-lib.sh by the
# oracles of tests/sh/ac-fleet-new.test.sh and tests/sh/ac-home-seed.test.sh
# (whose frozen entries call it) and by tests/ts/home-seed.test.ts, which pins
# the src/lib.ts twin seedRuntimeLinks to it.
ac_seed_runtime_links() {
  # ac_seed_runtime_links <home> - symlink the EXECUTABLE core into <home> so
  # a chief session runs with cwd = home (workspace = home, repo = code):
  # bin/ tooling, the CLAUDE.md chief law, .claude/ (settings/hooks/skills),
  # AGENTS.md. Nothing else: docs/ and tests/ are repo material read through
  # "$(ac_root)/..." when needed, and machine paths already resolve that way.
  # A REAL (non-symlink) entry is left alone - a per-home override wins; a
  # stale symlink is repointed.
  local home="$1" root f
  root="$(ac_root)"
  for f in bin CLAUDE.md .claude AGENTS.md; do
    if [ -e "$home/$f" ] && [ ! -L "$home/$f" ]; then continue; fi
    ln -sfn "$root/$f" "$home/$f"
  done
}
