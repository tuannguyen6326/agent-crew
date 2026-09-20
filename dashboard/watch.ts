// watch.ts - fleet-state file watchers for the dashboard: one hook call per
// home whenever a file ac-fleets.sh --json reads has moved, so the server can
// drop its snapshot memo instead of serving up to TTL_MS of stale accounting.
//
// Watchers only OBSERVE - nothing here writes, locks or shells out. Every
// failure is swallowed and logged: a home whose dirs are missing, a dir
// removed underneath a live watcher, or a platform refusing a watch option
// costs that surface its early invalidation, never the daemon.
//
// Verified on this host (Bun 1.3.13, macOS): a flat fs.watch on a dir reports
// content writes to existing files inside it; {recursive:true} on data/
// reports nested room.md writes and families created after the watch was
// armed; a missing path throws ENOENT synchronously; a removed dir goes
// silent with no error event. Recursive support elsewhere is not assumed -
// a throw there leaves state/ and records/ watched and only the room channel
// dark.

import { watch, type FSWatcher } from "node:fs";

export const WATCH_DEBOUNCE_MS = 300;

/** The surfaces that change between polls, each with the filename filter
 *  that decides whether an event is fleet state or noise (a beacon, a report,
 *  a tmp file mid tmp+rename). Filenames are relative to the watched dir. */
const SURFACES: { sub: string; recursive: boolean; matches: (f: string) => boolean }[] = [
  { sub: "state", recursive: false, matches: (f) => /\.(status|meta)$/.test(f) },
  { sub: "records", recursive: false, matches: (f) => f === "backlog.md" },
  { sub: "data", recursive: true, matches: (f) => /^[^/]+\/room\.md$/.test(f) },
];

export type HomeWatcher = {
  /** Watch exactly these homes: new ones are armed, dropped ones closed. */
  sync(homes: string[]): void;
  watched(): string[];
  close(): void;
};

type Entry = { watchers: FSWatcher[]; timer: ReturnType<typeof setTimeout> | null };

export function watchHomes(
  onChange: (home: string) => void,
  opts: { debounceMs?: number; log?: (line: string) => void } = {},
): HomeWatcher {
  const debounceMs = opts.debounceMs ?? WATCH_DEBOUNCE_MS;
  const log = opts.log ?? (() => {});
  const homes = new Map<string, Entry>();

  function arm(home: string): void {
    const entry: Entry = { watchers: [], timer: null };
    const fire = () => {
      if (entry.timer) clearTimeout(entry.timer);
      entry.timer = setTimeout(() => { entry.timer = null; onChange(home); }, debounceMs);
    };
    for (const s of SURFACES) {
      const path = `${home}/${s.sub}`;
      try {
        const w = watch(path, { recursive: s.recursive }, (_event, filename) => {
          if (typeof filename === "string" && s.matches(filename)) fire();
        });
        w.on("error", (err) => log(`watch ${path}: ${(err as Error).message}`));
        entry.watchers.push(w);
      } catch (err) {
        log(`watch ${path}: ${(err as Error).message}`);
      }
    }
    homes.set(home, entry);
  }

  function disarm(home: string): void {
    const entry = homes.get(home);
    if (!entry) return;
    if (entry.timer) clearTimeout(entry.timer);
    for (const w of entry.watchers) try { w.close(); } catch { /* already gone */ }
    homes.delete(home);
  }

  return {
    sync(next) {
      const want = new Set(next);
      for (const home of [...homes.keys()]) if (!want.has(home)) disarm(home);
      for (const home of want) if (!homes.has(home)) arm(home);
    },
    watched: () => [...homes.keys()],
    close() { for (const home of [...homes.keys()]) disarm(home); },
  };
}
