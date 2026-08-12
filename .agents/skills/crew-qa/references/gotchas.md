# crew-qa gotchas (read before the infra/serve phases)

Known failure modes of the qa pipeline's moving parts - grounded in research
and the panel review that shaped bin/ac-qa.sh.

- **Postgres 18 PGDATA moved** to `/var/lib/postgresql/18/docker`; the shipped
  compose template pins image and tmpfs path together - never bump one alone.
  An old-path tmpfs mount silently no-ops and your "fast ephemeral DB" writes
  to the container filesystem instead.
- **postgres healthcheck flaps during first-boot init** (the entrypoint starts
  the server twice); trust `--wait` + start_period, not a single green probe.
- **temporal is not ready when the port opens** - the frontend accepts
  connections tens of seconds before namespace registration. The template's
  healthcheck (`temporal operator namespace describe ... default`) is the
  readiness truth; never port-probe it.
- **redis on alpine + `localhost`** can resolve to IPv6 while redis binds
  IPv4 - probes must use `127.0.0.1` (the template does).
- **wiremock boots EMPTY** - it mocks nothing until you push stubs
  (`POST $QA_MOCK_URL/__admin/mappings`); reset between cases so case B never
  inherits case A's stubs. Verify the reset endpoint spelling against
  `$QA_MOCK_URL/__admin/docs` the first time.
- **serve inherits ONLY the minimal env** (ports.env + PATH/HOME/LANG). A
  service that needs more (API keys for mocks, feature flags) gets them via
  config-declared values, never your ambient shell - if it crashes on a
  missing var, that is the pre-flight gate working, not a bug in the tool.
- **`kill -0` on the serve pid during health** catches the classic
  died-during-boot case; read `<run>/logs/serve.log` before retrying.
- **Docker Desktop VM limits**: many parallel stacks OOM the VM into
  fleet-wide flaky false-fails. Check `ac-qa.sh infra status` for other
  crew-qa stacks before `up`; tear down promptly at finish.
- **Chrome MCP is headed-only and pauses on login/CAPTCHA** - fine when you
  can answer interactively, otherwise use the playwright fallback; long
  sessions can idle-drop the extension (reconnect before concluding
  "browser broken").
- **Screenshots default to viewport, not page** - pass `--full-page` when the
  verdict depends on anything below the fold; fix the viewport size so
  evidence is comparable between runs.
- **A text grep of a bundled report proves NOTHING about secrets.** Playwright's
  HTML report is self-contained: it inlines its attachments and trace data as
  base64/zip inside the HTML. `grep -r 'eyJ' report/` returns 0 matches while
  the JWT is fully present in the artifact - the bytes are there, just encoded.
  The scrub is therefore a RENDER-time act: redact in the DOM before you
  capture, then verify the ARTIFACT you are about to ship (`strings shot.png |
  grep -iE 'bearer|eyJ|secret|token'`), never the source it came from. The
  screenshot is what leaves the fleet, so the screenshot is what you scan.
- **`ac-qa.sh visual` sniffs magic bytes, not the extension** - `touch shot.png`
  or a saved HTML page named `.png` is refused, and the finish gate re-reads
  every registered file. Register artifacts you intend to KEEP: a screenshot
  registered from a framework temp dir (`/tmp/playwright-*`) stops counting the
  moment that dir is cleaned, and the run then cannot pass. Copy it into the
  evidence dir first, register the copy.
- **The live fleet store is not a verifier input.** A sanctioned round reads
  only `<run>/profile/store/`, whose versioned manifest and every selected file
  hash are bound by `profile_sha256`. An empty manifest is an explicit
  no-store result. Pointing the pane at `$AC_HOME/data/qa-store/...` would make
  the round change underneath its attestation.
- **A fixture pack is the reusable boundary.** Keep shared setup, schema
  discovery, seeds, and cleanup in one reviewed pack with named selectors.
  Read-write packs must be idempotent under retry; a selector that collides
  with its own previous state is not reusable evidence.
- **Do not edit an oracle to match current code.** Completing `testplan`
  freezes its hash. A real expectation change needs `testplan-amend`, every
  affected case id, a precise accepted authority, and a reason. Source behavior
  alone means `unverifiable` or `ask-user`.
- **The pane does not own its exported verdict.** `run.meta outcome` is the
  authority; a pane verdict claim is optional and must match. A facade error or
  mismatch publishes `verdict: error`, no caller verdict, and preserves
  recovery state.
- **`report.md` and `relay-report.md` are different artifacts.** The canonical
  stage report is atomically generated from durable state beside the QA brief.
  The relay report is a caller checklist. Never use one as a substitute for
  the other.
- **One profile round means one QA pane.** Project commands, browsers, workers,
  and safe concurrent checks are supervised subprocesses, not subagents.
  Source/profile/route/model/authority changes and capacity limits require a
  fresh round; no mid-pane model switch is valid.
