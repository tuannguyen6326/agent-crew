// ac-brain-engine.ts - the per-home memory engine (this header is the
// authoritative spec; design record: the fleet's data/ac-brain family).
//
// WHAT IT IS. A rebuildable SQLite index over a fleet home's own markdown
// (records/, data/, crewdomains/, CREWMATE-learned.md) plus a markdown-backed
// facts ledger (state/facts.md), exposed as memory verbs over a JSON CLI and
// an optional MCP stdio surface. Markdown stays the system of record for
// every data class: pages/chunks/links/aliases are DERIVED (sync owns them,
// `sync --rebuild` drops and rebuilds them), and facts are replayed from the
// append-only state/facts.md ledger, so the DB is disposable by construction.
//
// INVARIANTS (each carries its own reason):
// - PRAGMA busy_timeout is set BEFORE journal_mode=WAL on every open: the
//   journal_mode pragma is itself a write, and setting it first measurably
//   fails under multi-process contention instead of waiting.
// - ONE timestamp format everywhere (ISO 8601 UTC via iso()): the delta
//   keyset compares timestamp strings, so a second format at any write site
//   silently breaks at-least-once delivery.
// - Exact-hash dedup is deterministic and complete: canonical = fewest path
//   segments, then shortest slug, then lexicographic - a global fixpoint pass
//   over the pages table, never dependent on walk order. Demoted duplicates
//   are recorded in `shadows` so incremental sync skips their files by mtime
//   instead of re-reading them every pass.
// - Alias writes are idempotent (UNIQUE + INSERT OR IGNORE).
// - The mass-delete valve refuses a reconcile that would drop >50% of pages
//   when the index holds >20 - a moved or half-mounted home must not empty
//   the brain.
// - The sync lease is broken only for a provably dead PID (ESRCH), never on
//   staleness: a live holder mid-CHECKPOINT looks stale.
// - remember REQUIRES provenance; the write appends the ledger line and the
//   DB row inside one IMMEDIATE transaction so cross-process writers
//   serialize on SQLite's own lock.
// - Intent switch: >=5 informative query terms read as content-lookup and
//   run graded BM25 only; fewer read as name-lookup and add the title arm
//   plus gentle boosts. Fusion normalizes BM25 min-max so boosts reorder
//   near-ties, never graded relevance.
// - Every result carries its home-relative path, an evidence stamp, and the
//   response carries create_safety - recall must never lose to grep on
//   citability.
// - The pattern floor (push-gate patterns file) flags, never drops.
// - LLM boundaries: sync/recall/entity/context_pack/delta/remember/forget are
//   zero-LLM forever. The embedding lane (voyage|openai|stub) is an optional
//   vectorizer - absent config or key degrades to keyword-only with a stamp,
//   never an error. synthesize is the ONE expensive verb: it shells to the
//   fleet's own harness one-shot (env AC_BRAIN_SYNTH_CMD > crew-dispatch
//   panes.brain > config/model+crew-harness), falls back to an extractive
//   digest when compose fails but gather succeeded, and returns a typed
//   `unavailable` error on an empty gather or no harness - never a fabricated
//   answer.
// - Deputy reads are explicit only: recall --deputy <id> resolves the
//   absolute home: path from records/crewdeputies.md and opens that brain
//   READ-ONLY; there is no cross-brain write path.
// - Usage log: every verb appends one line to state/brain-usage.jsonl
//   (home-local, never uploaded) so later demand-signal work has evidence.
//
// CLI: ac-brain.sh is the wrapper; every command prints ONE JSON value.
//   sync [--rebuild] [--dry-run] [--no-embed] [--force-reconcile] [--break-lease]
//   recall [--query q] [--entity slug] [--agent a] [--since iso] [--limit n]
//          [--budget-tokens n] [--no-boosts] [--deputy id]
//   remember <fact> --provenance p --agent a [--entity slug] [--kind k] [--ttl 30d|iso]
//   forget <id> [--reason r]      entity <name>       links-to <target>
//   context_pack --entities a,b [--budget-tokens n]
//   delta --agent a --session s [--since iso]
//   synthesize <question>         doctor              stats
//   serve                         (MCP stdio, the seven verbs)
// Errors: {"error":<code>,"message":...,"suggestion":...} on stdout, exit 1.
import { Database } from "bun:sqlite";
import { readdirSync, statSync, readFileSync, existsSync, appendFileSync, mkdirSync, writeFileSync } from "fs";
import { join, relative, dirname, basename } from "path";
import { hostname } from "os";

const SCHEMA_VERSION = 1;
const CHUNKER_VERSION = 1;
const args = process.argv.slice(2);
const cmd = args[0];
function opt(name: string, dflt?: string): string | undefined {
  const i = args.indexOf("--" + name);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : dflt;
}
const flag = (name: string) => args.includes("--" + name);
const positional = (n: number) => {
  const out: string[] = [];
  for (let i = 1; i < args.length; i++) {
    if (args[i].startsWith("--")) { const nxt = args[i + 1]; if (nxt !== undefined && !nxt.startsWith("--") && !isBoolFlag(args[i])) i++; continue; }
    out.push(args[i]);
  }
  return out[n];
};
const BOOL_FLAGS = new Set(["--rebuild", "--dry-run", "--no-embed", "--force-reconcile", "--break-lease", "--no-boosts", "--compact"]);
const isBoolFlag = (a: string) => BOOL_FLAGS.has(a);

const HOME = opt("home", process.env.AC_HOME)!;
if (!HOME || !existsSync(HOME)) die("invalid_params", "no fleet home", "pass --home <abs path> or set AC_HOME");
const DB_PATH = join(HOME, "state", "brain.sqlite");
const FACTS_MD = join(HOME, "state", "facts.md");
const USAGE_LOG = join(HOME, "state", "brain-usage.jsonl");
const CONFIG = join(HOME, "config", "brain.json");

const iso = (ms?: number) => new Date(ms ?? Date.now()).toISOString();

function die(code: string, message: string, suggestion: string): never {
  console.log(JSON.stringify({ error: code, message, suggestion }));
  process.exit(1);
}
function out(v: unknown) { console.log(JSON.stringify(v, null, flag("compact") ? 0 : 1)); }
function usageLog(rec: Record<string, unknown>) {
  try { appendFileSync(USAGE_LOG, JSON.stringify({ at: iso(), ...rec }) + "\n"); } catch {}
}
function loadCfg(): any {
  try { return JSON.parse(readFileSync(CONFIG, "utf8")); } catch { return {}; }
}

// ---------- db ----------
function openDb(readonly = false): Database {
  if (!readonly) mkdirSync(join(HOME, "state"), { recursive: true });
  const db = new Database(DB_PATH, readonly ? { readonly: true } : { create: true });
  db.run("PRAGMA busy_timeout=5000");
  if (!readonly) {
    db.run("PRAGMA journal_mode=WAL");
    db.run("PRAGMA synchronous=NORMAL");
    migrate(db);
  }
  return db;
}
function migrate(db: Database) {
  db.run(`CREATE TABLE IF NOT EXISTS meta(k TEXT PRIMARY KEY, v TEXT)`);
  const v = (db.query("SELECT v FROM meta WHERE k='schema_version'").get() as any)?.v;
  if (v && Number(v) > SCHEMA_VERSION) die("internal", `brain schema v${v} is newer than this engine (v${SCHEMA_VERSION})`, "update agent-crew");
  db.run(`CREATE TABLE IF NOT EXISTS pages(
    slug TEXT PRIMARY KEY, title TEXT, type TEXT, family TEXT, path TEXT,
    mtime REAL, hash TEXT, updated_at TEXT, backlinks INTEGER DEFAULT 0, flags TEXT DEFAULT '')`);
  db.run(`CREATE TABLE IF NOT EXISTS shadows(path TEXT PRIMARY KEY, mtime REAL, hash TEXT, canonical_slug TEXT)`);
  db.run(`CREATE TABLE IF NOT EXISTS chunks(id INTEGER PRIMARY KEY, slug TEXT, ord INTEGER, text TEXT,
    embedding BLOB, embedded_at TEXT)`);
  db.run(`CREATE INDEX IF NOT EXISTS idx_chunks_slug ON chunks(slug)`);
  db.run(`CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(text, title, slug UNINDEXED, tokenize='porter unicode61')`);
  db.run(`CREATE VIRTUAL TABLE IF NOT EXISTS pages_fts USING fts5(title, aliases, slug UNINDEXED, tokenize='porter unicode61')`);
  db.run(`CREATE TABLE IF NOT EXISTS links(from_slug TEXT, to_slug TEXT, type TEXT, resolved INTEGER,
    UNIQUE(from_slug, to_slug, type))`);
  db.run(`CREATE INDEX IF NOT EXISTS idx_links_to ON links(to_slug)`);
  db.run(`CREATE TABLE IF NOT EXISTS aliases(alias TEXT, slug TEXT, UNIQUE(alias, slug))`);
  db.run(`CREATE TABLE IF NOT EXISTS facts(id INTEGER PRIMARY KEY, entity TEXT, fact TEXT,
    kind TEXT DEFAULT 'fact' CHECK(kind IN ('event','preference','commitment','belief','fact')),
    provenance TEXT NOT NULL, agent TEXT, family TEXT, valid_until TEXT,
    expired_at TEXT, expire_reason TEXT, superseded_by INTEGER,
    embedding BLOB, created_at TEXT)`);
  db.run(`CREATE INDEX IF NOT EXISTS idx_facts_entity ON facts(entity, created_at) WHERE expired_at IS NULL`);
  db.run(`CREATE INDEX IF NOT EXISTS idx_facts_since ON facts(created_at, id) WHERE expired_at IS NULL`);
  db.run(`CREATE TABLE IF NOT EXISTS cursors(agent TEXT, session TEXT, since_utc TEXT, since_slug TEXT,
    fact_since TEXT, fact_id INTEGER DEFAULT 0, updated_at TEXT, PRIMARY KEY(agent, session))`);
  db.run(`INSERT OR REPLACE INTO meta(k,v) VALUES('schema_version', ?)`, [String(SCHEMA_VERSION)]);
}

// ---------- parse / chunk / links ----------
const STOP = new Set("a an and are as at be by for from has have i in is it its of on or that the this to was were will with you your not no yes we our".split(" "));

function parsePage(raw: string, relPath: string) {
  let fm: Record<string, string> = {};
  let body = raw;
  if (raw.startsWith("---\n")) {
    const end = raw.indexOf("\n---", 4);
    if (end > 0) {
      for (const line of raw.slice(4, end).split("\n")) {
        const m = line.match(/^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$/);
        if (m) fm[m[1].toLowerCase()] = m[2].trim();
      }
      body = raw.slice(end + 4);
    }
  }
  const h1 = body.match(/^#\s+(.+)$/m);
  const title = fm.title || (h1 ? h1[1].trim() : basename(relPath, ".md").replace(/[-_]/g, " "));
  const famM = relPath.match(/^data\/([^/]+)\//);
  const domM = relPath.match(/^crewdomains\/([^/]+)\//);
  const family = fm.family || (famM ? famM[1] : domM ? "domain:" + domM[1] : "");
  let type = "note";
  if (relPath.startsWith("records/")) type = relPath.includes("repo-knowledge/") ? "knowledge" : relPath.includes("scenes/") ? "scene" : "record";
  else if (relPath.endsWith("/room.md")) type = "room";
  else if (/\/(requirements|spec|architecture|plan|report)\.md$/.test(relPath) || /\/(spec|arch|plan|implement|qa)\/report\.md$/.test(relPath)) type = "design-doc";
  else if (famM || domM) type = "family-doc";
  else if (relPath === "CREWMATE-learned.md") type = "learned";
  const aliases = (fm.aliases || "").replace(/[\[\]"']/g, "").split(",").map(s => s.trim()).filter(Boolean);
  const fmEdges: Array<{ to: string; type: string }> = [];
  for (const key of ["depends_on", "blocks", "owns", "supersedes", "see_also"])
    for (const t of (fm[key] || "").replace(/[\[\]"']/g, "").split(",").map(s => s.trim()).filter(Boolean))
      fmEdges.push({ to: t, type: key });
  return { title, type, family, body, aliases, fmEdges };
}

function chunkBody(body: string): string[] {
  const sections = body.split(/\n(?=## )/);
  const outC: string[] = [];
  for (const sec of sections) {
    if (sec.trim().length < 40) continue;
    if (sec.length <= 1600) { outC.push(sec.trim()); continue; }
    let buf = "";
    for (const para of sec.split(/\n\n+/)) {
      if (buf.length + para.length > 1600 && buf) { outC.push(buf.trim()); buf = ""; }
      buf += para + "\n\n";
      while (buf.length > 2400) { outC.push(buf.slice(0, 1600)); buf = buf.slice(1500); }
    }
    if (buf.trim().length >= 40) outC.push(buf.trim());
  }
  return outC.length ? outC : (body.trim().length >= 40 ? [body.trim().slice(0, 1600)] : []);
}

const CODE_REF = /(?:bin|tests|src|scripts|docs|\.agents)\/[A-Za-z0-9_\-./]+\.(?:sh|ts|md|json|py|yaml|go|rb)/g;
const WIKI = /\[\[([^\]|#]+)(?:#[^\]|]*)?(?:\|[^\]]*)?\]\]/g;
const MDLINK = /\]\(([^)\s]+\.md)\)/g;

function extractLinks(body: string, relPath: string, family: string, fmEdges: Array<{ to: string; type: string }>) {
  const masked = body.replace(/```[\s\S]*?```/g, "").replace(/`[^`]*`/g, "");
  const links: Array<{ to: string; type: string }> = [...fmEdges];
  for (const m of masked.matchAll(WIKI)) links.push({ to: m[1].trim(), type: "wikilink" });
  for (const m of masked.matchAll(MDLINK)) {
    let p = m[1];
    if (!p.startsWith("/") && !p.startsWith("http")) p = join(dirname(relPath), p);
    links.push({ to: p.replace(/\.md$/, ""), type: "mdlink" });
  }
  for (const m of masked.matchAll(CODE_REF)) links.push({ to: m[0], type: "cites_code" });
  for (const m of masked.matchAll(/data\/([a-z0-9][a-z0-9-]{2,})\//g))
    if (m[1] !== family) links.push({ to: "data/" + m[1] + "/room", type: "mentions_family" });
  return links;
}

// ---------- pattern floor ----------
function loadPatterns(): RegExp[] {
  const p = process.env.AC_BRAIN_PATTERN_FILE || join(process.env.HOME || "", ".config/agent-crew/push-gate.patterns");
  try {
    return readFileSync(p, "utf8").split("\n")
      .map(l => l.trim()).filter(l => l && !l.startsWith("#"))
      .map(l => { try { return new RegExp(l, "i"); } catch { return null; } })
      .filter((r): r is RegExp => r !== null);
  } catch { return []; }
}

// ---------- embedding lane ----------
type EmbedCfg = { provider: string; model: string; dims: number; base_url?: string; key_env?: string; auth?: string };
function embedCfg(): EmbedCfg | null {
  const e = loadCfg().embedding;
  if (!e?.provider) return null;
  return { provider: e.provider, model: e.model || "", dims: Number(e.dims) || 1024,
    base_url: e.base_url, key_env: e.key_env, auth: e.auth };
}
// PROVIDER REGISTRY - the public contract for model endpoints. Keys are NEVER
// in the repo or in brain.json: resolution is env var first, then the
// per-home secret store <home>/config/providers.json (operator-owned, 0600,
// gitignored with the rest of config/; the dashboard's Providers panel is its
// editor). A provider with key: false (ollama) needs none.
const PROVIDERS: Record<string, { base_url: string; env: string; key?: boolean }> = {
  openrouter: { base_url: "https://openrouter.ai/api/v1", env: "OPENROUTER_API_KEY" },
  openai: { base_url: "https://api.openai.com/v1", env: "OPENAI_API_KEY" },
  voyage: { base_url: "https://api.voyageai.com/v1", env: "VOYAGE_API_KEY" },
  "opencode-go": { base_url: "https://opencode.ai/zen/go/v1", env: "OPENCODE_API_KEY" },
  anthropic: { base_url: "https://api.anthropic.com/v1", env: "ANTHROPIC_API_KEY" },
  ollama: { base_url: "http://127.0.0.1:11434/v1", env: "", key: false },
  stub: { base_url: "", env: "", key: false },
};
function providersStore(): Record<string, { api_key?: string }> {
  try { return JSON.parse(readFileSync(join(HOME, "config", "providers.json"), "utf8")); } catch { return {}; }
}
function providerKey(name: string, key_env?: string): string | undefined {
  const reg = PROVIDERS[name];
  if (reg && reg.key === false) return "none";
  if (key_env && process.env[key_env]) return process.env[key_env];
  if (reg?.env && process.env[reg.env]) return process.env[reg.env];
  const k = providersStore()[name]?.api_key;
  return k && k.trim() ? k : undefined;
}
function providerBase(name: string, override?: string): string {
  return (override || PROVIDERS[name]?.base_url || "").replace(/\/$/, "");
}
function embedKey(c: EmbedCfg): string | undefined {
  return providerKey(c.provider, c.key_env);
}
function stubVec(text: string, dims: number): Float32Array {
  const v = new Float32Array(dims);
  for (const m of text.toLowerCase().matchAll(/[a-z0-9]+/g)) {
    let h = 0;
    for (const c of m[0]) h = (h * 31 + c.charCodeAt(0)) >>> 0;
    v[h % dims] += 1;
  }
  let n = 0; for (const x of v) n += x * x;
  n = Math.sqrt(n) || 1;
  for (let i = 0; i < dims; i++) v[i] /= n;
  return v;
}
async function embedBatch(texts: string[], cfg: EmbedCfg): Promise<Float32Array[] | null> {
  const key = embedKey(cfg);
  if (!key) return null;
  if (cfg.provider === "stub") return texts.map(t => stubVec(t, cfg.dims));
  const url = providerBase(cfg.provider, cfg.base_url) + "/embeddings";
  try {
    const r = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}`, "User-Agent": "agent-crew-brain/1.0" },
      body: JSON.stringify({ model: cfg.model, input: texts }),
    });
    if (!r.ok) return null;
    const j: any = await r.json();
    const rows = (j.data || []).map((d: any) => Float32Array.from(d.embedding));
    if (rows.length && rows[0].length !== cfg.dims)
      die("invalid_params", `embedding dims mismatch: provider returned ${rows[0].length}, config says ${cfg.dims}`,
        `set embedding.dims=${rows[0].length} in config/brain.json and run: ac-brain sync --rebuild`);
    return rows;
  } catch { return null; }
}
const toBlob = (v: Float32Array) => new Uint8Array(v.buffer.slice(0));
const fromBlob = (b: Uint8Array) => new Float32Array(b.buffer, b.byteOffset, b.byteLength / 4);
function cosine(a: Float32Array, b: Float32Array): number {
  let s = 0; const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) s += a[i] * b[i];
  return s;
}

// ---------- facts ledger (state/facts.md is the truth) ----------
type FactLine = { op: "f" | "x"; id: number; payload: any };
function readLedger(): FactLine[] {
  let raw = "";
  try { raw = readFileSync(FACTS_MD, "utf8"); } catch { return []; }
  const outL: FactLine[] = [];
  for (const line of raw.split("\n")) {
    const m = line.match(/^- ([fx])(\d+) (\{.*\})$/);
    if (!m) continue;
    try { outL.push({ op: m[1] as "f" | "x", id: Number(m[2]), payload: JSON.parse(m[3]) }); } catch {}
  }
  return outL;
}
function appendLedger(op: "f" | "x", id: number, payload: any) {
  mkdirSync(join(HOME, "state"), { recursive: true });
  if (!existsSync(FACTS_MD))
    appendFileSync(FACTS_MD, "# facts ledger - the TRUTH for ac-brain facts (append-only; the DB only indexes it)\n\n");
  appendFileSync(FACTS_MD, `- ${op}${id} ${JSON.stringify(payload)}\n`);
}
function replayLedgerInto(db: Database) {
  db.run("DELETE FROM facts");
  for (const l of readLedger()) {
    if (l.op === "f")
      db.run(`INSERT OR REPLACE INTO facts(id,entity,fact,kind,provenance,agent,family,valid_until,created_at)
              VALUES(?,?,?,?,?,?,?,?,?)`,
        [l.id, l.payload.entity ?? null, l.payload.fact, l.payload.kind ?? "fact", l.payload.provenance,
         l.payload.agent ?? null, l.payload.family ?? null, l.payload.ttl ?? null, l.payload.at]);
    else
      db.run("UPDATE facts SET expired_at=?, expire_reason=? WHERE id=?", [l.payload.at, l.payload.reason ?? null, l.id]);
  }
}
function ttlSweep(db: Database) {
  const now = iso();
  const lapsed = db.query("SELECT id FROM facts WHERE expired_at IS NULL AND valid_until IS NOT NULL AND valid_until < ?").all(now) as any[];
  for (const r of lapsed) {
    db.run("UPDATE facts SET expired_at=?, expire_reason='ttl' WHERE id=?", [now, r.id]);
    appendLedger("x", r.id, { at: now, reason: "ttl" });
  }
  return lapsed.length;
}

// ---------- sync ----------
function leaseGet(db: Database): any | null {
  const v = (db.query("SELECT v FROM meta WHERE k='sync_lease'").get() as any)?.v;
  try { return v ? JSON.parse(v) : null; } catch { return null; }
}
function pidAlive(pid: number): boolean {
  try { process.kill(pid, 0); return true; } catch (e: any) { return e.code === "EPERM"; }
}
function cmdSync() {
  const db = openDb();
  const t0 = performance.now();
  if (flag("break-lease")) {
    const l = leaseGet(db);
    if (!l) { out({ broke: false, reason: "no lease" }); return; }
    if (l.host === hostname() && !pidAlive(l.pid)) {
      db.run("DELETE FROM meta WHERE k='sync_lease'");
      out({ broke: true, dead_pid: l.pid });
    } else out({ broke: false, reason: "holder alive or foreign host", holder: l });
    return;
  }
  const l = leaseGet(db);
  if (l && l.host === hostname() && pidAlive(l.pid) && l.pid !== process.pid) {
    out({ status: "already-running", holder: l }); return;
  }
  db.run("INSERT OR REPLACE INTO meta(k,v) VALUES('sync_lease', ?)", [JSON.stringify({ host: hostname(), pid: process.pid, at: iso() })]);
  try { syncInner(db, t0); } finally { db.run("DELETE FROM meta WHERE k='sync_lease'"); }
}
function syncInner(db: Database, t0: number) {
  const dry = flag("dry-run");
  if (flag("rebuild") && !dry)
    for (const t of ["pages", "shadows", "chunks", "chunks_fts", "pages_fts", "links", "aliases"]) db.run(`DELETE FROM ${t}`);
  const cfg = loadCfg();
  const excludes = new Set<string>(cfg.excludes || ["state", "logs", "whiteboards", "skills-archive", "scenes-archive", "node_modules", ".git", ".crew"]);
  const files: string[] = [];
  const walk = (dir: string) => {
    let ents; try { ents = readdirSync(dir, { withFileTypes: true }); } catch { return; }
    for (const e of ents) {
      if (e.name.startsWith(".")) continue;
      if (e.isSymbolicLink()) continue;
      const p = join(dir, e.name);
      if (e.isDirectory()) { if (!excludes.has(e.name)) walk(p); }
      else if (e.name.endsWith(".md")) files.push(p);
    }
  };
  for (const src of cfg.sources || ["records", "data", "crewdomains"]) walk(join(HOME, src));
  for (const rf of ["CREWMATE-learned.md"]) if (existsSync(join(HOME, rf))) files.push(join(HOME, rf));

  const known = new Map<string, { mtime: number; hash: string }>();
  for (const r of db.query("SELECT path, mtime, hash FROM pages").all() as any[]) known.set(r.path, r);
  for (const r of db.query("SELECT path, mtime, hash FROM shadows").all() as any[]) known.set(r.path, r);
  const patterns = loadPatterns();
  const seenPaths = new Set<string>();
  let changed = 0, skippedMtime = 0, skippedHash = 0, flagged = 0;
  type Item = { slug: string; path: string; title: string; type: string; family: string; mtime: number; hash: string;
    updated: string; chunks: string[]; aliases: string[]; links: Array<{ to: string; type: string }>; flags: string };
  const batch: Item[] = [];
  for (const f of files) {
    const rel = relative(HOME, f);
    seenPaths.add(rel);
    const st = statSync(f);
    const prev = known.get(rel);
    if (prev && prev.mtime === st.mtimeMs) { skippedMtime++; continue; }
    const raw = readFileSync(f, "utf8");
    const hash = new Bun.CryptoHasher("sha256").update(raw).digest("hex");
    if (prev && prev.hash === hash) {
      skippedHash++;
      if (!dry) { db.run("UPDATE pages SET mtime=? WHERE path=?", [st.mtimeMs, rel]); db.run("UPDATE shadows SET mtime=? WHERE path=?", [st.mtimeMs, rel]); }
      continue;
    }
    const p = parsePage(raw, rel);
    if (p.body.trim().length < 40) {
      // empty/trivial page: never indexed, but it must ride the mtime index
      // (a shadows row with no canonical) or every sync re-reads it forever
      if (!dry) db.run("INSERT OR REPLACE INTO shadows(path,mtime,hash,canonical_slug) VALUES(?,?,?, '')", [rel, st.mtimeMs, hash]);
      continue;
    }
    const chunks = chunkBody(p.body);
    let flags = "";
    if (patterns.length && patterns.some(re => chunks.some(c => re.test(c)))) { flags = "pattern-hit"; flagged++; }
    batch.push({ slug: rel.replace(/\.md$/, ""), path: rel, title: p.title, type: p.type, family: p.family,
      mtime: st.mtimeMs, hash, updated: iso(st.mtimeMs), chunks, aliases: p.aliases,
      links: extractLinks(p.body, rel, p.family, p.fmEdges), flags });
    changed++;
  }
  if (dry) { out({ dry_run: true, files: files.length, would_change: changed, skipped_mtime: skippedMtime, skipped_hash: skippedHash }); return; }

  const tx = db.transaction((items: Item[]) => {
    for (const it of items) {
      for (const [t, c] of [["pages", "slug"], ["chunks", "slug"], ["chunks_fts", "slug"], ["pages_fts", "slug"], ["links", "from_slug"], ["aliases", "slug"]])
        db.run(`DELETE FROM ${t} WHERE ${c}=?`, [it.slug]);
      db.run("DELETE FROM shadows WHERE path=?", [it.path]);
      db.run(`INSERT OR REPLACE INTO pages(slug,title,type,family,path,mtime,hash,updated_at,backlinks,flags) VALUES(?,?,?,?,?,?,?,?,0,?)`,
        [it.slug, it.title, it.type, it.family, it.path, it.mtime, it.hash, it.updated, it.flags]);
      it.chunks.forEach((c, i) => {
        db.run("INSERT INTO chunks(slug,ord,text) VALUES(?,?,?)", [it.slug, i, c]);
        db.run("INSERT INTO chunks_fts(text,title,slug) VALUES(?,?,?)", [c, it.title, it.slug]);
      });
      db.run("INSERT INTO pages_fts(title,aliases,slug) VALUES(?,?,?)", [it.title, it.aliases.join(" "), it.slug]);
      for (const a of it.aliases) db.run("INSERT OR IGNORE INTO aliases(alias,slug) VALUES(?,?)", [a.toLowerCase(), it.slug]);
      for (const lk of it.links) db.run("INSERT OR IGNORE INTO links(from_slug,to_slug,type,resolved) VALUES(?,?,?,0)", [it.slug, lk.to, lk.type]);
    }
  });
  tx(batch);

  // delete-reconcile with the mass-delete valve
  const gonePages = (db.query("SELECT slug, path FROM pages").all() as any[]).filter(r => !seenPaths.has(r.path));
  const totalPages = (db.query("SELECT COUNT(*) c FROM pages").get() as any).c;
  let deleted = 0, refusedReconcile = false;
  if (gonePages.length && totalPages > 20 && gonePages.length / totalPages > 0.5 && !flag("force-reconcile")) {
    refusedReconcile = true;
  } else {
    for (const r of gonePages) {
      for (const [t, c] of [["pages", "slug"], ["chunks", "slug"], ["chunks_fts", "slug"], ["pages_fts", "slug"], ["links", "from_slug"], ["aliases", "slug"]])
        db.run(`DELETE FROM ${t} WHERE ${c}=?`, [r.slug]);
      deleted++;
    }
    for (const r of (db.query("SELECT path FROM shadows").all() as any[]).filter(r => !seenPaths.has(r.path)))
      db.run("DELETE FROM shadows WHERE path=?", [r.path]);
  }

  // deterministic fixpoint dedup: canonical = fewest segments, shortest slug, lexicographic
  const groups = db.query("SELECT hash FROM pages GROUP BY hash HAVING COUNT(*) > 1").all() as any[];
  let deduped = 0;
  for (const g of groups) {
    const members = (db.query("SELECT slug, path FROM pages WHERE hash=?").all(g.hash) as any[])
      .sort((a, b) => (a.slug.split("/").length - b.slug.split("/").length) || (a.slug.length - b.slug.length) || (a.slug < b.slug ? -1 : 1));
    const canon = members[0];
    for (const m of members.slice(1)) {
      const row = db.query("SELECT mtime, hash FROM pages WHERE slug=?").get(m.slug) as any;
      for (const [t, c] of [["pages", "slug"], ["chunks", "slug"], ["chunks_fts", "slug"], ["pages_fts", "slug"], ["links", "from_slug"]])
        db.run(`DELETE FROM ${t} WHERE ${c}=?`, [m.slug]);
      db.run("INSERT OR REPLACE INTO shadows(path,mtime,hash,canonical_slug) VALUES(?,?,?,?)", [m.path, row?.mtime ?? 0, g.hash, canon.slug]);
      db.run("INSERT OR IGNORE INTO aliases(alias,slug) VALUES(?,?)", [m.slug, canon.slug]);
      deduped++;
    }
  }

  // link resolution: direct slug, then basename (ON by default - home slugs are unambiguous enough)
  const slugSet = new Set((db.query("SELECT slug FROM pages").all() as any[]).map(r => r.slug));
  const base = new Map<string, string[]>();
  for (const s of slugSet) {
    const b = s.split("/").pop()!;
    (base.get(b) ?? base.set(b, []).get(b)!).push(s);
  }
  db.run("UPDATE links SET resolved=0 WHERE type != 'cites_code'");
  for (const lrow of db.query("SELECT rowid, to_slug, type FROM links WHERE type != 'cites_code'").all() as any[]) {
    const t = lrow.to_slug.replace(/\.md$/, "");
    let target: string | null = null;
    if (slugSet.has(t)) target = t;
    else if (slugSet.has("data/" + t + "/room")) target = "data/" + t + "/room"; // bare family name
    else {
      const cands = base.get(t.split("/").pop()!) || base.get(t.toLowerCase().replace(/\s+/g, "-")) || [];
      if (cands.length >= 1) target = cands.slice().sort()[0];
    }
    // two raw refs may resolve to one (from,to,type) - REPLACE keeps a single edge
    if (target) db.run("UPDATE OR REPLACE links SET to_slug=?, resolved=1 WHERE rowid=?", [target, lrow.rowid]);
  }
  db.run("UPDATE pages SET backlinks=(SELECT COUNT(*) FROM links WHERE to_slug=pages.slug AND resolved=1)");

  const sweptTtl = ttlSweep(db);
  if (flag("rebuild")) replayLedgerInto(db);
  db.run("INSERT OR REPLACE INTO meta(k,v) VALUES('last_sync', ?)", [iso()]);
  db.run("INSERT OR REPLACE INTO meta(k,v) VALUES('chunker_version', ?)", [String(CHUNKER_VERSION)]);
  // Freshness marker for bash callers (the watcher's brain-freshen slot):
  // mtime is the signal, so a stat answers "how stale" without opening sqlite.
  try { writeFileSync(HOME + "/state/.brain-last-sync", iso() + "\n"); } catch {}

  const stats = {
    files: files.length, changed, deduped, deleted, refused_reconcile: refusedReconcile,
    skipped_mtime: skippedMtime, skipped_hash: skippedHash, flagged, ttl_swept: sweptTtl,
    pages: (db.query("SELECT COUNT(*) c FROM pages").get() as any).c,
    chunks: (db.query("SELECT COUNT(*) c FROM chunks").get() as any).c,
    ms: Math.round(performance.now() - t0),
  };
  // embedding backfill (batched, best-effort; keyless => stamp and continue)
  const ec = embedCfg();
  let embedded = 0, embedDegraded: string | undefined;
  if (ec && !flag("no-embed")) {
    const metaDims = (db.query("SELECT v FROM meta WHERE k='embed_dims'").get() as any)?.v;
    if (metaDims && Number(metaDims) !== ec.dims) {
      db.run("DELETE FROM meta WHERE k='sync_lease'"); // die() skips the finally
      die("invalid_params", `index embedded at ${metaDims} dims but config says ${ec.dims}`, "run: ac-brain sync --rebuild (re-embeds at the new width)");
    }
    const pending = db.query("SELECT id, slug, text FROM chunks WHERE embedding IS NULL LIMIT 4096").all() as any[];
    (async () => {})();
    embedDegraded = embedKey(ec) ? undefined : "no_api_key";
    if (!embedDegraded && pending.length) {
      const upd = db.prepare("UPDATE chunks SET embedding=?, embedded_at=? WHERE id=?");
      // synchronous await via Bun top-level not available in function: do it with a promise loop
      const run = async () => {
        for (let i = 0; i < pending.length; i += 64) {
          const slice = pending.slice(i, i + 64);
          const vecs = await embedBatch(slice.map(r => r.text), ec);
          if (!vecs) { embedDegraded = "provider_error"; return; }
          const t2 = db.transaction(() => {
            slice.forEach((r, j) => { upd.run(toBlob(vecs[j]), iso(), r.id); embedded++; });
          });
          t2();
        }
        db.run("INSERT OR REPLACE INTO meta(k,v) VALUES('embed_dims', ?)", [String(ec.dims)]);
      };
      // @ts-ignore  top-level style await through then-chain before printing
      globalThis.__embedPromise = run();
    }
  } else if (!ec) embedDegraded = "no_provider_configured";
  const finish = () => { usageLog({ verb: "sync", changed, ms: stats.ms }); out({ ...stats, embedded, embed_degraded: embedDegraded }); };
  const p = (globalThis as any).__embedPromise;
  if (p) p.then(finish); else finish();
}

// ---------- retrieval ----------
function ftsQuery(q: string) {
  const terms = [...q.toLowerCase().matchAll(/[a-z0-9][a-z0-9._-]+/g)].map(m => m[0].replace(/[._-]+$/, ""))
    .filter(t => t.length > 1 && !STOP.has(t));
  const quoted = terms.map(t => `"${t}"`);
  return { and: quoted.join(" "), or: quoted.join(" OR "), terms };
}
type Hit = { slug: string; title?: string; family?: string; type?: string; path?: string; score: number; evidence: string; snippet?: string; trust?: string; origin?: string };

async function searchArm(db: Database, q: string, limit: number, boosts: boolean): Promise<{ hits: Hit[]; degraded?: string }> {
  const { and, or, terms } = ftsQuery(q);
  if (!terms.length) return { hits: [] };
  if (terms.length >= 5) boosts = false; // intent: content-lookup - graded BM25 must not be reordered
  const run = (match: string) => db.query(
    `SELECT slug, title, snippet(chunks_fts, 0, '', '', '…', 14) snip, bm25(chunks_fts, 1.0, 2.5) s
     FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY s LIMIT 60`).all(match) as any[];
  let kw: any[] = [];
  try { kw = run(and); } catch {}
  if (!kw.length) { try { kw = run(or); } catch {} }
  let titleArm: any[] = [];
  if (boosts) {
    const runT = (m: string) => db.query(`SELECT slug, bm25(pages_fts, 2.0, 1.5) s FROM pages_fts WHERE pages_fts MATCH ? ORDER BY s LIMIT 30`).all(m) as any[];
    try { titleArm = runT(and); } catch {}
    if (!titleArm.length) { try { titleArm = runT(or); } catch {} }
  }
  // vector arm
  let degraded: string | undefined;
  const ec = embedCfg();
  const vecScores = new Map<string, number>();
  if (ec) {
    if (!embedKey(ec)) degraded = "keyword_only_no_api_key";
    else {
      const qv = (await embedBatch([q], ec))?.[0];
      if (!qv) degraded = "keyword_only_provider_error";
      else {
        const rows = db.query("SELECT slug, embedding FROM chunks WHERE embedding IS NOT NULL").all() as any[];
        if (!rows.length) degraded = "keyword_only_unembedded_index";
        for (const r of rows) {
          const c = cosine(qv, fromBlob(r.embedding));
          if (c > (vecScores.get(r.slug) ?? -1)) vecScores.set(r.slug, c);
        }
      }
    }
  } else degraded = "keyword_only_no_provider";
  // normalized fusion: boosts may only reorder near-ties, never graded relevance
  const norm = (rows: any[]) => {
    if (!rows.length) return new Map();
    const vals = rows.map(r => -r.s);
    const lo = Math.min(...vals), hi = Math.max(...vals), span = hi - lo || 1;
    return new Map(rows.map(r => [r, (-r.s - lo) / span]));
  };
  const kwN = norm(kw);
  const tN = norm(titleArm);
  const fused = new Map<string, { score: number; snip?: string; title?: string }>();
  const seen = new Set<string>();
  for (const r of kw) {
    if (seen.has(r.slug)) continue;
    seen.add(r.slug);
    fused.set(r.slug, { score: 0.2 + 0.8 * (kwN.get(r) as number), snip: r.snip, title: r.title });
  }
  for (const r of titleArm) {
    const e = fused.get(r.slug) || { score: 0 };
    e.score += 0.35 * (tN.get(r) as number);
    fused.set(r.slug, e);
  }
  if (vecScores.size) {
    // Vector is a FIRST-CLASS arm: normalize over its own top-60 candidates
    // and fuse by max(arm scores) + a quarter of the weaker arm as an
    // agreement bonus. A capped additive weight measurably buried
    // cross-language hits under same-language keyword noise (VN query, EN
    // page: pure cosine ranked the target 5th, fused rank lost it).
    const top60 = [...vecScores.entries()].sort((a, b) => b[1] - a[1]).slice(0, 60);
    const vals = top60.map(e => e[1]);
    const lo = Math.min(...vals), hi = Math.max(...vals), span = hi - lo || 1;
    for (const [slug, c] of top60) {
      const vScore = 0.15 + 0.85 * ((c - lo) / span);
      const e = fused.get(slug) || { score: 0 };
      const kwScore = e.score;
      e.score = Math.max(kwScore, vScore) + Math.min(kwScore, vScore) * 0.25;
      fused.set(slug, e);
    }
  }
  const meta = new Map<string, any>();
  if (fused.size) {
    const slugs = [...fused.keys()];
    const ph = slugs.map(() => "?").join(",");
    for (const r of db.query(`SELECT slug, title, family, type, path, backlinks, mtime, flags FROM pages WHERE slug IN (${ph})`).all(...slugs) as any[])
      meta.set(r.slug, r);
  }
  const now = Date.now();
  const ql = q.toLowerCase();
  const hits: Hit[] = [...fused.entries()].map(([slug, e]) => {
    const m = meta.get(slug) || {};
    let score = e.score, evidence = vecScores.has(slug) && !kw.some(r => r.slug === slug) ? "vector" : "keyword";
    if (boosts) {
      score *= 1 + 0.02 * Math.log(1 + (m.backlinks || 0));
      const days = (now - (m.mtime || now)) / 86400000;
      score *= 1 + 0.08 * (30 / (30 + days));
      const tl = (m.title || "").toLowerCase();
      if (tl && (tl === ql || tl.includes(ql))) { score *= 1.15; evidence = "title_phrase"; }
      if (slug.toLowerCase().includes(ql.replace(/\s+/g, "-"))) { score *= 1.3; evidence = "slug_match"; }
      const hitCount = terms.filter(t => tl.includes(t)).length;
      if (evidence === "keyword" && terms.length && hitCount === terms.length) evidence = "title_all_terms";
    }
    const trust = m.type === "knowledge" ? "L1-verified (re-check freshness marker)"
      : m.type === "learned" ? "L3-promoted" : "unverified working material";
    return { slug, title: m.title, family: m.family, type: m.type, path: m.path, score, evidence, snippet: e.snip, trust };
  }).sort((a, b) => b.score - a.score).slice(0, limit);
  return { hits, degraded };
}

// Optional precision knob: cross-encoder rerank of the fused top-N, then
// autocut at the largest normalized score cliff. Gated on config/brain.json
// reranker{provider,model} + its key; provider "stub" (term-overlap) exists
// so tests prove the plumbing without a paid call. Fail-open: any error
// returns the fused order untouched.
async function rerankHits(q: string, hits: Hit[]): Promise<{ hits: Hit[]; reranked: boolean }> {
  const rc = loadCfg().reranker;
  if (!rc?.provider || hits.length < 3) return { hits, reranked: false };
  const top = hits.slice(0, 20), tail = hits.slice(20);
  let scores: number[] | null = null;
  if (rc.provider === "stub") {
    const terms = ftsQuery(q).terms;
    scores = top.map(h => terms.filter(t => ((h.title || "") + " " + (h.snippet || "")).toLowerCase().includes(t)).length);
  } else if (rc.provider === "voyage" && process.env.VOYAGE_API_KEY) {
    try {
      const r = await fetch("https://api.voyageai.com/v1/rerank", {
        method: "POST", headers: { "Content-Type": "application/json", Authorization: `Bearer ${process.env.VOYAGE_API_KEY}` },
        body: JSON.stringify({ model: rc.model || "rerank-2.5", query: q, documents: top.map(h => (h.title || "") + "\n" + (h.snippet || "")) }),
      });
      if (r.ok) {
        const j: any = await r.json();
        scores = new Array(top.length).fill(0);
        for (const d of j.data || []) scores[d.index] = d.relevance_score;
      }
    } catch {}
  }
  if (!scores) return { hits, reranked: false };
  const order = top.map((h, i) => ({ h, s: scores![i] })).sort((a, b) => b.s - a.s);
  // autocut: largest gap in the normalized rerank scores, keep at least 1
  const vals = order.map(o => o.s);
  const lo = Math.min(...vals), span = (Math.max(...vals) - lo) || 1;
  let cut = order.length, biggest = 0.25; // a cliff must beat 25% of the range
  for (let i = 1; i < order.length; i++) {
    const gap = (order[i - 1].s - order[i].s) / span;
    if (gap > biggest) { biggest = gap; cut = i; }
  }
  return { hits: [...order.slice(0, cut).map(o => o.h), ...order.slice(cut).map(o => o.h), ...tail], reranked: true };
}

const estTokens = (s: string) => Math.ceil((s || "").length / 4);
function packToBudget<T>(items: T[], cost: (x: T) => number, budget: number): { kept: T[]; used: number; dropped: number } {
  let used = 0; const kept: T[] = [];
  for (const it of items) {
    const c = cost(it);
    if (used + c > budget) break;
    used += c; kept.push(it);
  }
  return { kept, used, dropped: items.length - kept.length };
}

async function cmdRecall() {
  const db = openDb();
  const t0 = performance.now();
  const q = opt("query"), entity = opt("entity"), agent = opt("agent"), since = opt("since");
  const limit = Math.min(Number(opt("limit", "8")), 50);
  const budget = opt("budget-tokens") ? Number(opt("budget-tokens")) : undefined;
  // facts arm
  let facts: any[] = [];
  if (entity || agent || since || !q) {
    let sql = "SELECT id, entity, fact, kind, provenance, agent, valid_until, created_at FROM facts WHERE expired_at IS NULL";
    const p: any[] = [];
    if (entity) { sql += " AND entity=?"; p.push(entity); }
    if (agent) { sql += " AND agent=?"; p.push(agent); }
    if (since) { sql += " AND created_at >= ?"; p.push(since); }
    sql += " ORDER BY created_at DESC LIMIT ?"; p.push(limit);
    facts = db.query(sql).all(...p) as any[];
  }
  // search arm
  let hits: Hit[] = [], degraded: string | undefined, reranked = false;
  if (q) {
    const r = await searchArm(db, q, limit, !flag("no-boosts"));
    hits = r.hits; degraded = r.degraded;
    const rr = await rerankHits(q, hits);
    hits = rr.hits;
    if (rr.reranked) reranked = true;
    const dep = opt("deputy");
    if (dep) {
      const dHome = deputyHome(dep);
      if (dHome) {
        const dPath = join(dHome, "state", "brain.sqlite");
        if (existsSync(dPath)) {
          const ddb = new Database(dPath, { readonly: true });
          ddb.run("PRAGMA busy_timeout=3000");
          const saved = { home: HOME };
          const dr = await searchArmOn(ddb, q, limit);
          for (const h of dr) hits.push({ ...h, origin: "deputy:" + dep });
          hits.sort((a, b) => b.score - a.score);
          hits = hits.slice(0, limit);
          ddb.close();
          void saved;
        }
      } else degraded = (degraded ? degraded + ";" : "") + "deputy_not_found";
    }
  }
  let budget_used: number | undefined, dropped = 0;
  if (budget) {
    const pf = packToBudget(facts, f => estTokens(f.fact) + 8, budget);
    facts = pf.kept;
    const remain = budget - pf.used;
    const ph = packToBudget(hits, h => estTokens(h.snippet || "") + estTokens(h.title || "") + 10, Math.max(0, remain));
    hits = ph.kept;
    budget_used = pf.used + ph.used;
    dropped = pf.dropped + ph.dropped;
  }
  // create_safety: would a page for this query-as-name already exist?
  const top = hits[0];
  const create_safety = top && (top.evidence === "slug_match" || top.evidence === "title_phrase") ? "exists"
    : top && top.evidence === "title_all_terms" ? "probable" : "unknown";
  const ms = Math.round((performance.now() - t0) * 10) / 10;
  usageLog({ verb: "recall", q: q ?? null, entity: entity ?? null, hits: hits.length, ms });
  out({ protocol_version: 1, facts, total: facts.length, results: hits, create_safety, ...(reranked ? { reranked: true } : {}),
    ...(degraded ? { search_degraded: degraded } : {}),
    ...(budget ? { budget_tokens: budget, budget_used, dropped_count: dropped } : {}), ms });
}
// deputy read-only arm: keyword-only (a deputy's embedding config is its own)
async function searchArmOn(db: Database, q: string, limit: number): Promise<Hit[]> {
  const { and, or, terms } = ftsQuery(q);
  if (!terms.length) return [];
  const run = (m: string) => db.query(
    `SELECT slug, title, snippet(chunks_fts, 0, '', '', '…', 14) snip, bm25(chunks_fts, 1.0, 2.5) s
     FROM chunks_fts WHERE chunks_fts MATCH ? ORDER BY s LIMIT ?`).all(m, limit) as any[];
  let kw: any[] = [];
  try { kw = run(and); } catch {}
  if (!kw.length) { try { kw = run(or); } catch {} }
  const seen = new Set<string>();
  const outH: Hit[] = [];
  for (const r of kw) {
    if (seen.has(r.slug)) continue;
    seen.add(r.slug);
    outH.push({ slug: r.slug, title: r.title, score: 0.5, evidence: "keyword", snippet: r.snip });
  }
  return outH;
}
function deputyHome(id: string): string | null {
  try {
    const reg = readFileSync(join(HOME, "records", "crewdeputies.md"), "utf8");
    for (const line of reg.split("\n")) {
      const m = line.match(/^- (\S+) .*home: (\S+)/);
      if (m && m[1] === id) return m[2];
    }
  } catch {}
  return null;
}

// ---------- facts verbs ----------
async function cmdRemember() {
  const fact = positional(0);
  const provenance = opt("provenance");
  if (!fact) die("invalid_params", "no fact text", "ac-brain remember '<fact>' --provenance '<source>' --agent <id>");
  if (!provenance || !provenance.trim())
    die("provenance_required", "every fact carries its source", "add --provenance '<where this came from>' (e.g. \"captain 2026-08-16\", \"session xyz\")");
  if (provenance.length > 500) die("invalid_params", "provenance > 500 chars", "shorten it; provenance is an attribution, not a document");
  const kind = opt("kind", "fact")!;
  if (!["event", "preference", "commitment", "belief", "fact"].includes(kind))
    die("invalid_params", `unknown kind '${kind}'`, "kind is one of event|preference|commitment|belief|fact");
  let ttl: string | null = null;
  const ttlRaw = opt("ttl");
  if (ttlRaw) {
    const m = ttlRaw.match(/^(\d+)([smhd])$/);
    if (m) ttl = iso(Date.now() + Number(m[1]) * { s: 1e3, m: 6e4, h: 36e5, d: 864e5 }[m[2] as "s"]!);
    else if (!isNaN(Date.parse(ttlRaw))) ttl = iso(Date.parse(ttlRaw));
    else die("invalid_params", `unparseable ttl '${ttlRaw}'`, "use shorthand (30d, 12h, 45m) or an ISO 8601 timestamp");
  }
  const entity = opt("entity") ?? null, agent = opt("agent") ?? null, family = opt("family") ?? null;
  const db = openDb();
  // dedup: exact text per entity; embedding-similarity supersede when vectors exist
  const dup = db.query("SELECT id FROM facts WHERE fact=? AND ifnull(entity,'')=ifnull(?,'') AND expired_at IS NULL").get(fact, entity) as any;
  if (dup) { usageLog({ verb: "remember", status: "duplicate" }); out({ protocol_version: 1, id: dup.id, status: "duplicate" }); return; }
  let superseded: number | null = null;
  const ec = embedCfg();
  let vec: Float32Array | null = null;
  if (ec && embedKey(ec) && entity) {
    vec = (await embedBatch([fact], ec))?.[0] ?? null;
    if (vec) {
      const cands = db.query("SELECT id, fact, kind, embedding FROM facts WHERE entity=? AND expired_at IS NULL AND embedding IS NOT NULL").all(entity) as any[];
      for (const c of cands) {
        const sim = cosine(vec, fromBlob(c.embedding));
        if (sim >= 0.95) {
          if (c.kind === kind && c.fact.replace(/\s+/g, " ").toLowerCase() !== fact.replace(/\s+/g, " ").toLowerCase()) { superseded = c.id; break; }
          usageLog({ verb: "remember", status: "duplicate" });
          out({ protocol_version: 1, id: c.id, status: "duplicate" });
          return;
        }
      }
    }
  }
  const at = iso();
  const txn = db.transaction(() => {
    const nextId = ((db.query("SELECT MAX(id) m FROM facts").get() as any)?.m ?? 0) + 1;
    db.run(`INSERT INTO facts(id,entity,fact,kind,provenance,agent,family,valid_until,embedding,created_at) VALUES(?,?,?,?,?,?,?,?,?,?)`,
      [nextId, entity, fact, kind, provenance, agent, family, ttl, vec ? toBlob(vec) : null, at]);
    appendLedger("f", nextId, { fact, entity, kind, provenance, agent, family, ttl, at });
    if (superseded) {
      db.run("UPDATE facts SET expired_at=?, expire_reason=?, superseded_by=? WHERE id=?", [at, "superseded", nextId, superseded]);
      appendLedger("x", superseded, { at, reason: `superseded by f${nextId}` });
    }
    return nextId;
  });
  const id = txn.immediate();
  usageLog({ verb: "remember", status: superseded ? "superseded" : "inserted" });
  out({ protocol_version: 1, id, status: superseded ? "superseded" : "inserted", superseded,
    valid_until: ttl, ...(ec && !embedKey(ec) ? { degraded_dedup: true } : ec ? {} : { degraded_dedup: true }) });
}
function cmdForget() {
  const id = Number(positional(0));
  if (!id) die("invalid_params", "no fact id", "ac-brain forget <id> [--reason r]  (ids come from recall.facts[].id)");
  const db = openDb();
  const row = db.query("SELECT id, expired_at FROM facts WHERE id=?").get(id) as any;
  if (!row) die("not_found", `no fact ${id}`, "list active facts with: ac-brain recall --entity <slug>");
  if (row.expired_at) { out({ protocol_version: 1, id, expired: false, note: "already expired" }); return; }
  const at = iso();
  const reason = opt("reason") ?? null;
  const txn = db.transaction(() => {
    db.run("UPDATE facts SET expired_at=?, expire_reason=? WHERE id=?", [at, reason, id]);
    appendLedger("x", id, { at, reason });
  });
  txn.immediate();
  usageLog({ verb: "forget", id });
  out({ protocol_version: 1, id, expired: true, reason });
}

// ---------- entity / context_pack / delta ----------
function entityCard(db: Database, name: string) {
  const n = name.toLowerCase();
  const byAlias = db.query("SELECT p.* FROM aliases a JOIN pages p ON p.slug=a.slug WHERE a.alias=?").all(n) as any[];
  const byTitle = db.query("SELECT * FROM pages WHERE lower(title)=?").all(n) as any[];
  const bySlug = db.query("SELECT * FROM pages WHERE slug=? OR slug LIKE ?").all(n, "%/" + n) as any[];
  const best = byAlias[0] || byTitle[0] || bySlug[0];
  if (!best) return null;
  const edges = db.query("SELECT to_slug, type FROM links WHERE from_slug=? AND resolved=1 LIMIT 10").all(best.slug);
  const facts = db.query("SELECT id, fact, kind, provenance, agent FROM facts WHERE entity=? AND expired_at IS NULL ORDER BY created_at DESC LIMIT 10").all(best.slug);
  const commitments = (facts as any[]).filter(f => f.kind === "commitment").slice(0, 3);
  return { slug: best.slug, title: best.title, family: best.family, type: best.type, path: best.path,
    backlinks: best.backlinks, updated_at: best.updated_at, edges, facts, open_threads: commitments };
}
function cmdEntity() {
  const name = positional(0);
  if (!name) die("invalid_params", "no name", "ac-brain entity <name>");
  const db = openDb();
  const t0 = performance.now();
  const card = entityCard(db, name);
  const ms = Math.round((performance.now() - t0) * 10) / 10;
  usageLog({ verb: "entity", name, found: !!card, ms });
  if (!card) {
    const near = db.query(`SELECT slug, title FROM pages_fts WHERE pages_fts MATCH ? LIMIT 3`).all(ftsQuery(name).or || '""') as any[];
    out({ protocol_version: 1, found: false, latency_ms: ms, suggestions: near });
    return;
  }
  out({ protocol_version: 1, found: true, latency_ms: ms, card });
}
function cmdContextPack() {
  const ents = (opt("entities") || "").split(",").map(s => s.trim()).filter(Boolean).slice(0, 8);
  if (!ents.length) die("invalid_params", "no entities", "ac-brain context_pack --entities fam-a,records/backlog [--budget-tokens n]");
  const db = openDb();
  const budget = opt("budget-tokens") ? Number(opt("budget-tokens")) : undefined;
  let cards = ents.map(e => entityCard(db, e)).filter(Boolean) as any[];
  let facts = db.query("SELECT id, entity, fact, kind, agent, created_at FROM facts WHERE expired_at IS NULL ORDER BY created_at DESC LIMIT 30").all() as any[];
  let budget_used: number | undefined, dropped = 0;
  const cardCost = (c: any) => estTokens(c.title) + estTokens(JSON.stringify(c.edges)) + c.facts.reduce((s: number, f: any) => s + estTokens(f.fact), 0);
  if (budget) {
    const pc = packToBudget(cards, cardCost, budget);
    cards = pc.kept;
    const pf = packToBudget(facts, f => estTokens(f.fact) + 8, Math.max(0, budget - pc.used));
    facts = pf.kept;
    budget_used = pc.used + pf.used;
    dropped = pc.dropped + pf.dropped;
  }
  const text = cards.map(c =>
    `## ${c.title} (${c.slug})\n${c.facts.map((f: any) => `- [${f.kind}] ${f.fact} (${f.provenance})`).join("\n")}`).join("\n\n");
  usageLog({ verb: "context_pack", entities: ents.length });
  out({ protocol_version: 1, entities: ents, cards, facts, text,
    ...(budget ? { budget_tokens: budget, budget_used, dropped_count: dropped } : {}) });
}
function cmdDelta() {
  const agent = opt("agent"), session = opt("session");
  if (!agent || !session) die("invalid_params", "delta needs an identity", "ac-brain delta --agent <pane-or-chief-id> --session <room-or-session-id>");
  const db = openDb();
  const explicit = opt("since");
  const cur = db.query("SELECT * FROM cursors WHERE agent=? AND session=?").get(agent, session) as any;
  if (!cur && !explicit) {
    db.run("INSERT INTO cursors(agent,session,since_utc,since_slug,fact_since,fact_id,updated_at) VALUES(?,?,?,?,?,0,?)",
      [agent, session, iso(), "", iso(), iso()]);
    out({ protocol_version: 1, first_wake: true, pages: [], facts: [], has_more: false }); return;
  }
  const sinceUtc = explicit ?? cur.since_utc, sinceSlug = explicit ? "" : cur.since_slug;
  const factSince = explicit ?? cur?.fact_since ?? sinceUtc;
  const factId = explicit ? 0 : cur?.fact_id ?? 0;
  const lim = 50;
  const pages = db.query(
    `SELECT slug, title, family, type, path, updated_at FROM pages
     WHERE (updated_at > ?) OR (updated_at = ? AND slug > ?)
     ORDER BY updated_at ASC, slug ASC LIMIT ?`).all(sinceUtc, sinceUtc, sinceSlug, lim + 1) as any[];
  const hasMorePages = pages.length > lim;
  const delivered = pages.slice(0, lim);
  const facts = db.query(
    `SELECT id, entity, fact, kind, provenance, agent, created_at FROM facts
     WHERE expired_at IS NULL AND ((created_at > ?) OR (created_at = ? AND id > ?))
     ORDER BY created_at ASC, id ASC LIMIT ?`).all(factSince, factSince, factId, lim + 1) as any[];
  const hasMoreFacts = facts.length > lim;
  const fDelivered = facts.slice(0, lim);
  if (!explicit) {
    // deliver-before-advance, per stream
    const np = delivered.length ? delivered[delivered.length - 1] : null;
    const nf = fDelivered.length ? fDelivered[fDelivered.length - 1] : null;
    db.run(`UPDATE cursors SET since_utc=?, since_slug=?, fact_since=?, fact_id=?, updated_at=? WHERE agent=? AND session=?`,
      [np ? np.updated_at : (hasMorePages ? sinceUtc : iso(Date.now() - 2000)),
       np ? np.slug : (hasMorePages ? sinceSlug : ""),
       nf ? nf.created_at : (hasMoreFacts ? factSince : iso(Date.now() - 2000)),
       nf ? nf.id : (hasMoreFacts ? factId : 0),
       iso(), agent, session]);
    db.run("DELETE FROM cursors WHERE updated_at < ?", [iso(Date.now() - 7 * 864e5)]);
  }
  usageLog({ verb: "delta", agent, pages: delivered.length, facts: fDelivered.length });
  out({ protocol_version: 1, since: sinceUtc, pages: delivered, facts: fDelivered,
    has_more: hasMorePages || hasMoreFacts,
    next_cursor: { since: delivered.length ? delivered[delivered.length - 1].updated_at : sinceUtc,
                   slug: delivered.length ? delivered[delivered.length - 1].slug : sinceSlug } });
}

// ---------- links-to / stats / doctor ----------
function cmdLinksTo() {
  const target = positional(0);
  if (!target) die("invalid_params", "no target", "ac-brain links-to <path-or-slug-substring>");
  const db = openDb();
  const rows = db.query(`SELECT from_slug, type, COUNT(*) n FROM links WHERE to_slug LIKE ? GROUP BY from_slug, type ORDER BY n DESC LIMIT 40`)
    .all("%" + target + "%") as any[];
  const fams = [...new Set(rows.map(r => (r.from_slug.match(/^data\/([^/]+)\//) || [])[1]).filter(Boolean))];
  usageLog({ verb: "links-to", target, n: rows.length });
  out({ target, referencing_pages: rows.length, families: fams, top: rows.slice(0, 15) });
}
function cmdStats() {
  const db = openDb(true);
  const g = (q: string) => { try { return (db.query(q).get() as any).c; } catch { return 0; } };
  out({
    pages: g("SELECT COUNT(*) c FROM pages"), chunks: g("SELECT COUNT(*) c FROM chunks"),
    embedded: g("SELECT COUNT(*) c FROM chunks WHERE embedding IS NOT NULL"),
    links: g("SELECT COUNT(*) c FROM links"), resolved: g("SELECT COUNT(*) c FROM links WHERE resolved=1"),
    code_refs: g("SELECT COUNT(*) c FROM links WHERE type='cites_code'"),
    facts_active: g("SELECT COUNT(*) c FROM facts WHERE expired_at IS NULL"),
    facts_total: g("SELECT COUNT(*) c FROM facts"), shadows: g("SELECT COUNT(*) c FROM shadows"),
    last_sync: (db.query("SELECT v FROM meta WHERE k='last_sync'").get() as any)?.v ?? null,
    db_bytes: existsSync(DB_PATH) ? statSync(DB_PATH).size : 0,
  });
}
function cmdDoctor() {
  const checks: Array<{ name: string; status: string; message?: string }> = [];
  const push = (name: string, ok: boolean, message?: string) => checks.push({ name, status: ok ? "ok" : "fail", message });
  let db: Database | null = null;
  try { db = openDb(); push("open", true); } catch (e: any) { push("open", false, String(e)); }
  if (db) {
    const v = (db.query("SELECT v FROM meta WHERE k='schema_version'").get() as any)?.v;
    push("schema_version", Number(v) === SCHEMA_VERSION, `v${v}`);
    try { db.query(`SELECT COUNT(*) c FROM chunks_fts WHERE chunks_fts MATCH '"doctorprobe"'`).get(); push("fts", true); }
    catch (e: any) { push("fts", false, String(e)); }
    const orphans = (db.query("SELECT COUNT(*) c FROM chunks WHERE slug NOT IN (SELECT slug FROM pages)").get() as any).c;
    push("no_orphan_chunks", orphans === 0, `${orphans} orphans`);
    const dupGroups = (db.query("SELECT COUNT(*) c FROM (SELECT hash FROM pages GROUP BY hash HAVING COUNT(*) > 1)").get() as any).c;
    push("dedup_complete", dupGroups === 0, `${dupGroups} duplicate groups`);
    const ec = embedCfg();
    const metaDims = (db.query("SELECT v FROM meta WHERE k='embed_dims'").get() as any)?.v;
    if (ec && metaDims) push("embed_dims", Number(metaDims) === ec.dims, `index ${metaDims} vs config ${ec.dims}`);
    const lease = leaseGet(db);
    if (lease) push("sync_lease", true, pidAlive(lease.pid) ? `live holder pid ${lease.pid}` : `stale (dead pid ${lease.pid}; the next sync reclaims it)`);
    const ledgerActive = readLedger().reduce((s, l) => s + (l.op === "f" ? 1 : 0), 0);
    const dbTotal = (db.query("SELECT COUNT(*) c FROM facts").get() as any).c;
    push("facts_ledger_indexed", ledgerActive === dbTotal, `ledger ${ledgerActive} vs db ${dbTotal} (fix: sync --rebuild)`);
  }
  const failed = checks.filter(c => c.status === "fail");
  out({ status: failed.length ? "unhealthy" : "healthy", checks });
  if (failed.length) process.exit(1);
}

// ---------- synthesize (the ONE expensive verb) ----------
function synthCommand(): string | null {
  // Resolution, most specific first (same knob family as gate-agent/qa):
  //   AC_BRAIN_SYNTH_CMD (tests/operator override)
  //   > crew-dispatch.json panes.brain rule   (per-shape routing)
  //   > config/brain-agent + brain-model + brain-effort   (brain's own defaults)
  //   > config/crew-harness + config/model    (fleet-wide defaults)
  if (process.env.AC_BRAIN_SYNTH_CMD) return process.env.AC_BRAIN_SYNTH_CMD;
  const knob = (n: string) => { try { return readFileSync(join(HOME, "config", n), "utf8").trim().split("\n")[0]; } catch { return ""; } };
  let harness = "", model = "", effort = "";
  try {
    const d = JSON.parse(readFileSync(join(HOME, "config", "crew-dispatch.json"), "utf8"));
    const rule = d?.panes?.brain;
    if (rule?.harness) { harness = rule.harness; model = rule.model || ""; effort = rule.effort || ""; }
  } catch {}
  if (!harness) { harness = knob("brain-agent"); model = knob("brain-model"); effort = knob("brain-effort"); }
  if (!harness) { harness = knob("crew-harness"); model = model || knob("model"); }
  const mm = model ? ` --model ${model}` : "";
  // effort reaches the harnesses that take it on a one-shot line (codex config
  // override, pi --thinking); claude/opencode/cursor one-shots ignore it.
  switch (harness) {
    case "claude": return `claude -p${mm}`;
    case "codex": return `codex exec${model ? ` -m ${model}` : ""}${effort ? ` -c model_reasoning_effort=${effort}` : ""}`;
    case "opencode": return `opencode run${mm}`;
    case "pi": return `pi -p${mm}${effort ? ` --thinking ${effort}` : ""}`;
    case "cursor": return `cursor-agent -p --trust${mm}`;
    default: return null;
  }
}
async function cmdSynthesize() {
  const q = positional(0);
  if (!q) die("invalid_params", "no question", "ac-brain synthesize '<question>'");
  const db = openDb();
  const t0 = performance.now();
  const gathered = (await searchArm(db, q, 8, true)).hits;
  if (!gathered.length)
    die("unavailable", "retrieved 0 pages; nothing to synthesize from", "sync first, or ask a question the home's records can answer");
  const cmdline = synthCommand();
  const sources = gathered.map(h => ({ slug: h.slug, path: h.path }));
  // Full best-matching chunks, not display snippets - a composer cannot cite
  // from 14-word fragments (its own first live answer said exactly that).
  const ctx = gathered.map(h => {
    const rows = db.query("SELECT text FROM chunks WHERE slug=? ORDER BY ord LIMIT 3").all(h.slug) as any[];
    const body = rows.map(r => r.text).join("\n").slice(0, 4000);
    return `### ${h.title} (${h.slug})\n${body || h.snippet || ""}`;
  }).join("\n\n");
  const prompt = `Answer strictly from the sources below; cite slugs; state gaps honestly.\n\nQUESTION: ${q}\n\nSOURCES:\n${ctx}`;
  let answer: string | null = null, status = "ok";
  // Direct API branch: config/brain.json synthesize.api {base_url, model,
  // key_env|auth} calls an OpenAI-compatible chat endpoint - cheaper and
  // faster than spawning a harness; any failure falls through to the
  // harness/extractive ladder below.
  const sApi = loadCfg().synthesize?.api;
  if (sApi?.model && (sApi.provider || sApi.base_url)) {
    const key = providerKey(sApi.provider || "", sApi.key_env);
    if (key) {
      try {
        const r = await fetch(providerBase(sApi.provider || "", sApi.base_url) + "/chat/completions", {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: `Bearer ${key}`, "User-Agent": "agent-crew-brain/1.0" },
          body: JSON.stringify({ model: sApi.model, messages: [{ role: "user", content: prompt }], max_tokens: 1500 }),
          signal: AbortSignal.timeout(120000),
        });
        if (r.ok) {
          const jj: any = await r.json();
          const text = (jj.choices?.[0]?.message?.content || "").trim();
          if (text) answer = text;
        }
      } catch {}
      if (!answer) status = "llm_error";
    }
  }
  if (!answer && cmdline) {
    try {
      const proc = Bun.spawnSync(["bash", "-lc", `${cmdline} ${JSON.stringify(prompt)}`], { timeout: 180000 });
      const text = new TextDecoder().decode(proc.stdout).trim();
      if (proc.exitCode === 0 && text) { answer = text; status = "ok"; }
      else status = "llm_error";
    } catch { status = "llm_error"; }
  } else if (!answer && !sApi?.model) status = "no_llm";
  if (!answer) {
    // extractive fallback: compose ONLY from gathered pages, never fabricate
    answer = gathered.slice(0, 5).map(h => `- ${h.title} (${h.slug}): ${h.snippet || ""}`).join("\n");
    status = status === "ok" ? "extractive_fallback" : status + ";extractive_fallback";
  }
  usageLog({ verb: "synthesize", ms: Math.round(performance.now() - t0) });
  out({ protocol_version: 1, answer, sources, synthesis_status: status, gathered: gathered.length });
}

// ---------- MCP stdio serve (the seven verbs) ----------
const MCP_TOOLS = [
  { name: "recall", description: "Retrieve saved facts and search the home's records; returns ranked, cited results.", inputSchema: { type: "object", properties: { query: { type: "string" }, entity: { type: "string" }, since: { type: "string" }, limit: { type: "number" }, budget_tokens: { type: "number" } } } },
  { name: "remember", description: "Save ONE working-memory fact with mandatory provenance.", inputSchema: { type: "object", properties: { fact: { type: "string" }, provenance: { type: "string" }, entity: { type: "string" }, kind: { type: "string" }, ttl: { type: "string" }, agent: { type: "string" } }, required: ["fact", "provenance"] } },
  { name: "entity", description: "One known page/family card - zero LLM, never errors on a miss.", inputSchema: { type: "object", properties: { name: { type: "string" } }, required: ["name"] } },
  { name: "synthesize", description: "EXPENSIVE: LLM-composed answer with citations over retrieved pages.", inputSchema: { type: "object", properties: { question: { type: "string" } }, required: ["question"] } },
  { name: "forget", description: "Expire a fact by id (audited, idempotent).", inputSchema: { type: "object", properties: { id: { type: "number" }, reason: { type: "string" } }, required: ["id"] } },
  { name: "context_pack", description: "Deterministic budget-packed bundle of entity cards + hot facts.", inputSchema: { type: "object", properties: { entities: { type: "string" }, budget_tokens: { type: "number" } }, required: ["entities"] } },
  { name: "delta", description: "What changed since the caller's cursor - at-least-once, keyset paged.", inputSchema: { type: "object", properties: { agent: { type: "string" }, session: { type: "string" }, since: { type: "string" } }, required: ["agent", "session"] } },
];
async function cmdServe() {
  // ndjson JSON-RPC 2.0 over stdio; each tools/call re-execs this engine so the
  // verb implementations stay single-sourced and every call is a fresh process.
  const engine = process.argv[1];
  const send = (m: unknown) => process.stdout.write(JSON.stringify(m) + "\n");
  for await (const lineRaw of console) {
    const line = String(lineRaw).trim();
    if (!line) continue;
    let msg: any;
    try { msg = JSON.parse(line); } catch { continue; }
    const id = msg.id;
    if (msg.method === "initialize")
      send({ jsonrpc: "2.0", id, result: { protocolVersion: msg.params?.protocolVersion || "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "ac-brain", version: "1.0" } } });
    else if (msg.method === "tools/list")
      send({ jsonrpc: "2.0", id, result: { tools: MCP_TOOLS } });
    else if (msg.method === "tools/call") {
      const tool = msg.params?.name;
      const a = msg.params?.arguments || {};
      const argv: string[] = ["bun", engine, tool, "--home", HOME, "--compact"];
      const pos = tool === "remember" ? a.fact : tool === "synthesize" ? a.question : tool === "forget" ? String(a.id) : tool === "entity" ? a.name : undefined;
      if (pos !== undefined) argv.push(pos);
      for (const [k, v] of Object.entries(a)) {
        if (["fact", "question", "id", "name"].includes(k) && pos !== undefined) continue;
        argv.push("--" + k.replace(/_/g, "-"), String(v));
      }
      if (!MCP_TOOLS.some(t => t.name === tool)) {
        send({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text: JSON.stringify({ error: "unknown_tool" }) }], isError: true } });
        continue;
      }
      const proc = Bun.spawnSync(argv);
      const text = new TextDecoder().decode(proc.stdout).trim() || new TextDecoder().decode(proc.stderr).trim();
      send({ jsonrpc: "2.0", id, result: { content: [{ type: "text", text }], isError: proc.exitCode !== 0 } });
    } else if (id !== undefined)
      send({ jsonrpc: "2.0", id, error: { code: -32601, message: "method not found" } });
  }
}

// ---------- dispatch ----------
const CMDS: Record<string, () => unknown> = {
  sync: cmdSync, recall: cmdRecall, remember: cmdRemember, forget: cmdForget,
  entity: cmdEntity, "context_pack": cmdContextPack, delta: cmdDelta,
  "links-to": cmdLinksTo, stats: cmdStats, doctor: cmdDoctor,
  synthesize: cmdSynthesize, serve: cmdServe,
};
if (!cmd || !CMDS[cmd]) die("invalid_params", `unknown command '${cmd ?? ""}'`, "commands: " + Object.keys(CMDS).join(" "));
await CMDS[cmd]();
