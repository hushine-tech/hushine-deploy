# Document Center Phase 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a read-only Hushine document center with an independent Markdown repository, immutable release package, authenticated backend delivery, ordered reading, responsive rendering, and local full-text search.

**Architecture:** `hushine-docs` owns current Markdown and builds an immutable package. `hushine-deploy` binds that package to the exact multi-repository deployment and publishes it through an atomic `current` symlink. `quant-handler` is the only HTTP file boundary and filters content by the authenticated user; `quant-frontend` renders the authorized package and searches its prebuilt index in the browser.

**Tech Stack:** Node.js 22 built-in test runner for document packaging, Go 1.26 standard library for `quant-handler`, React 19 + TypeScript + react-markdown for the portal, Vitest + Testing Library for UI tests, Bash/Python standard library for deployment packaging.

**Spec:** `hushine-deploy/docs/superpowers/specs/2026-08-31-document-center-design.md`

## Global Constraints

- The portal is permanently read-only; no create, edit, delete, draft, or online Markdown editor exists.
- Phase 1 uses a fixed read-only directory and atomic symlink; it does not add MinIO, S3, Elasticsearch, a vector database, or OpenAI.
- The canonical content repository is `hushine-docs`; migrated current documents must be removed from the active operator index in `hushine-deploy` so two current sources do not remain.
- Only `quant-handler` may read the package for the browser. The frontend never receives an arbitrary filesystem path.
- Every content, asset, search, and manifest response is filtered by authenticated user scope on the backend.
- Ordinary users receive user manual, concepts, and public API documents. User IDs listed by `DOCS_PRIVILEGED_USER_IDS` additionally receive architecture, internal API, and operations documents.
- Dated Superpowers/OpenSpec files, historical audits, temporary test reports, secrets, logs, user strategy source, and coverage output never enter the release package.
- The package records `docs_commit` plus exact repository commits and image digests from the deployment manifest.
- Existing Hushine behavior and existing API routes remain unchanged when `DOCS_ROOT` is absent or invalid.

---

## File Structure

### New `hushine-docs` repository

- `package.json` — deterministic build and test commands.
- `docs-manifest.json` — canonical section, document, ordering, path, keywords, and visibility metadata.
- `content/user-manual/*.md` — user-facing pages.
- `content/architecture/*.md` — service/API/algorithm pages.
- `content/operations/*.md` — deployment and operations pages.
- `assets/` — document-owned images only.
- `scripts/lib/manifest.mjs` — schema and path validation.
- `scripts/lib/markdown.mjs` — link extraction and plain-text indexing.
- `scripts/build.mjs` — immutable package builder.
- `tests/build.test.mjs` and `tests/content.test.mjs` — package and corpus gates.

### `hushine-deploy`

- `scripts/docs/deployment-manifest.py` — exact repository commit/image manifest generator.
- `scripts/docs/build-release.sh` — invoke `hushine-docs` build with the deployment manifest.
- `scripts/docs/publish-release.sh` — copy a verified release and atomically switch `current`.
- `scripts/docs-release.test.sh` — packaging, secret exclusion, and atomic publication contract.
- `Makefile` — `docs-build`, `docs-publish`, and `local-docs` targets.
- `scripts/prepare-local-configs.py` — emit the local `DOCS_ROOT` equivalent into quant-handler config.
- `README.md` — clone map and document release commands.
- `docs/README.md` — transition notice pointing operators to the portal source repository.

### `gateway/quant-handler`

- `internal/docsstore/model.go` — manifest/search/document DTOs and visibility types.
- `internal/docsstore/store.go` — immutable snapshot loader, package verification, filtering, and safe asset access.
- `internal/docsstore/store_test.go` — snapshot, permission, traversal, and atomic-switch tests.
- `internal/app/docs.go` — authenticated docs HTTP handlers.
- `internal/app/docs_test.go` — route/method/status/permission tests.
- `internal/config/config.go`, `internal/config/config_test.go`, `config.yaml` — docs root and privileged-user configuration.
- `internal/app/app.go` — store construction and route registration.

### `gateway/quant-frontend`

- `src/api/docs.ts` — document API types and calls.
- `src/features/docs/search.ts` — deterministic browser search/scoring.
- `src/features/docs/search.test.ts` — English/Chinese/title/body scoring tests.
- `src/features/docs/DocsNavigation.tsx` — ordered tree and previous/next links.
- `src/features/docs/DocsSearch.tsx` — search input/results without model calls.
- `src/features/docs/DocsReader.tsx` — sanitized Markdown renderer.
- `src/features/docs/docs.css` — isolated responsive three-column styles.
- `src/pages/DocumentationCenter.tsx` and `.test.tsx` — page orchestration and UI behavior.
- `src/test/setup.ts`, `vitest.config.ts` — real component-test harness.
- `src/App.tsx` — bottom navigation entry and protected `/docs` routes.
- `src/api/client.ts` — export the existing base/error helpers for the focused docs client.
- `package.json`, lockfile — Markdown and test dependencies/scripts.

---

### Task 1: Bootstrap the deterministic `hushine-docs` package builder

**Files:**
- Create repository: `hushine-docs/`
- Create: `hushine-docs/package.json`
- Create: `hushine-docs/.gitignore`
- Create: `hushine-docs/docs-manifest.json`
- Create: `hushine-docs/scripts/lib/manifest.mjs`
- Create: `hushine-docs/scripts/lib/markdown.mjs`
- Create: `hushine-docs/scripts/build.mjs`
- Test: `hushine-docs/tests/build.test.mjs`

**Interfaces:**
- Consumes: `node scripts/build.mjs --deployment <file> --out <directory>`.
- Produces: `dist/<docs_commit>/{manifest.json,search-index.json,content/**,assets/**}`.
- Manifest document shape: `{id, slug, title, section_id, order, visibility, path, keywords}` where `visibility` is exactly `public` or `privileged`.

- [ ] **Step 1: Initialize the independent repository and failing build test**

Create the repository on branch `main`, then write a `node:test` case that builds a temporary two-document fixture and asserts the four output groups and SHA-256 content checksums exist.

```js
assert.equal(release.schema_version, 1);
assert.equal(release.docs_commit, docsCommit);
assert.deepEqual(release.deployment.repositories, deployment.repositories);
assert.match(release.documents[0].sha256, /^[a-f0-9]{64}$/);
assert.equal(searchIndex.documents[0].text.includes("Wallet balance"), true);
```

- [ ] **Step 2: Run the test and verify the builder is absent**

Run: `cd hushine-docs && node --test tests/build.test.mjs`

Expected: FAIL because `scripts/build.mjs` cannot be imported or executed.

- [ ] **Step 3: Implement strict manifest and path validation**

Export these exact functions:

```js
export function parseDocsManifest(value) {}
export function resolvePackagePath(root, relativePath) {}
export function validateInternalLinks(markdown, knownSlugs, sourcePath) {}
export function markdownToSearchText(markdown) {}
```

`parseDocsManifest` rejects duplicate section IDs, document IDs, slugs, paths, unknown visibility, non-integer order, missing files, and paths leaving the repository root. `validateInternalLinks` rejects unresolved relative Markdown links and assets; `http`, `https`, `mailto`, and same-page anchors remain external/anchor links.

- [ ] **Step 4: Implement deterministic package generation**

The builder must sort sections and documents by `(order, id)`, copy only manifest-listed content/assets, compute SHA-256 hashes, normalize generated JSON with two-space indentation and a final newline, and refuse to overwrite a non-empty release directory with different contents.

`generated_at` must come from `SOURCE_DATE_EPOCH`; `hushine-deploy` supplies the `hushine-docs` commit timestamp. The builder must not read the wall clock, so rebuilding the same docs/deployment inputs produces byte-identical output.

The release manifest must contain:

```json
{
  "schema_version": 1,
  "docs_commit": "<40 hex>",
  "generated_at": "<RFC3339 UTC>",
  "deployment": {"repositories": [], "images": []},
  "sections": [],
  "documents": []
}
```

- [ ] **Step 5: Run builder tests and a reproducibility check**

Run: `cd hushine-docs && npm test`

Run the same fixture build twice with a fixed `SOURCE_DATE_EPOCH`; expected: all files have identical hashes.

- [ ] **Step 6: Commit the builder**

```bash
git add package.json .gitignore docs-manifest.json scripts tests
git commit -m "feat: build immutable document releases"
```

### Task 2: Migrate and validate the current document corpus

**Files:**
- Create: `hushine-docs/content/user-manual/{overview,backtest,demo-live,wallet-and-orders}.md`
- Create: `hushine-docs/content/architecture/{system-overview,exchange-adapters,runtime-channel,strategy-leverage,spot-usdt}.md`
- Create: `hushine-docs/content/operations/{local-development,database-bootstrap,funding-income,production-deploy,local-docker,runtime-operator-flow}.md`
- Modify: `hushine-docs/docs-manifest.json`
- Test: `hushine-docs/tests/content.test.mjs`

**Interfaces:**
- Consumes: current verified material in `hushine-deploy/docs`, `hushine-deploy/db/README.md`, and `hushine-deploy/README.md`.
- Produces: three ordered sections and fifteen current pages with no repository-external links.

- [ ] **Step 1: Write the failing corpus policy test**

Assert exact section order `user-manual`, `architecture`, `operations`; assert every manifest document exists; assert no published path contains `/superpowers/`, `/openspec/`, `/test-reports/`, `/bug-reports/`, `.env`, `secret`, `credential`, or `coverage`.

Also fail on these migrated-link patterns:

```js
for (const forbidden of ["../README.md", "../db/README.md", "file://", "/Users/"]) {
  assert.equal(allMarkdown.includes(forbidden), false);
}
```

- [ ] **Step 2: Run the corpus test and verify it fails**

Run: `cd hushine-docs && node --test tests/content.test.mjs`

Expected: FAIL because the manifest pages are not present.

- [ ] **Step 3: Migrate current content using the fixed map**

Use this mapping and rewrite cross-document links to stable document slugs:

```text
hushine-deploy/docs/user-manual.md                         -> user-manual/overview.md
hushine-deploy/docs/user-manual/backtest.md                -> user-manual/backtest.md
hushine-deploy/docs/user-manual/demo-live.md               -> user-manual/demo-live.md
new wallet/order concepts extracted from verified code     -> user-manual/wallet-and-orders.md
hushine-deploy/README.md                                    -> architecture/system-overview.md
hushine-deploy/docs/architecture/exchange-adapters.md       -> architecture/exchange-adapters.md
hushine-deploy/docs/architecture/runtime-channel.md         -> architecture/runtime-channel.md
hushine-deploy/docs/strategy-owned-futures-leverage.md      -> architecture/strategy-leverage.md
hushine-deploy/docs/spot-usdt.md                            -> architecture/spot-usdt.md
hushine-deploy/docs/operations/local-development.md         -> operations/local-development.md
hushine-deploy/db/README.md                                 -> operations/database-bootstrap.md
hushine-deploy/docs/operations/funding-income.md            -> operations/funding-income.md
hushine-deploy/docs/production-deploy-checklist.md          -> operations/production-deploy.md
hushine-deploy/docs/local-docker.md                         -> operations/local-docker.md
hushine-deploy/docs/runtime-operator-flow.md                -> operations/runtime-operator-flow.md
```

Do not copy dated “last verified” claims without rechecking the referenced current code/config. Preserve formulas, field names, commands, and failure semantics exactly.

- [ ] **Step 4: Build the corpus and verify all links**

Run: `cd hushine-docs && npm test && npm run build -- --deployment tests/fixtures/deployment.json --out "$TMPDIR/hushine-docs-build"`

Expected: PASS; release contains exactly fifteen documents in the declared order.

- [ ] **Step 5: Commit current content**

```bash
git add content docs-manifest.json tests/content.test.mjs
git commit -m "docs: publish current Hushine manuals"
```

### Task 3: Bind and atomically publish document releases from `hushine-deploy`

**Files:**
- Create: `hushine-deploy/scripts/docs/deployment-manifest.py`
- Create: `hushine-deploy/scripts/docs/build-release.sh`
- Create: `hushine-deploy/scripts/docs/publish-release.sh`
- Test: `hushine-deploy/scripts/docs-release.test.sh`
- Modify: `hushine-deploy/Makefile`
- Modify: `hushine-deploy/README.md`
- Modify: `hushine-deploy/scripts/prepare-local-configs.py`
- Modify: `hushine-deploy/scripts/local-configs.test.sh`

**Interfaces:**
- Produces: `make docs-build`, `make docs-publish`, and `make local-docs`.
- Local published root: `$(SOURCE_ROOT)/.generated/docs/current`.
- Production published root: `/var/lib/hushine/docs/current`.

- [ ] **Step 1: Write the failing release contract**

The shell test creates temporary git repositories and verifies:

```text
deployment manifest records exact HEAD commits
dirty repositories are rejected unless ALLOW_DIRTY_DOCS_RELEASE=true
release build rejects missing hushine-docs
publish verifies every content checksum
current is a relative symlink to releases/<docs_commit>
a failed second publish leaves the first current target unchanged
```

- [ ] **Step 2: Run the release contract and verify missing commands**

Run: `cd hushine-deploy && bash scripts/docs-release.test.sh`

Expected: FAIL because the docs release scripts do not exist.

- [ ] **Step 3: Implement the deployment manifest generator**

`deployment-manifest.py` accepts `--source-root` and `--output`, reads exact commits for the repositories named in the service map, and emits sorted JSON:

```json
{
  "schema_version": 1,
  "repositories": [{"name": "core-service", "commit": "<40 hex>"}],
  "images": [{"name": "strategy-runtime", "digest": "sha256:<64 hex>"}]
}
```

No file content, remote URL, branch name, secret, or dirty diff enters this manifest.

- [ ] **Step 4: Implement build and atomic publication**

`build-release.sh` invokes the `hushine-docs` builder into a temporary directory and renames only a verified complete release. `publish-release.sh` copies to `releases/<docs_commit>`, verifies hashes again, creates `current.next`, then renames the symlink to `current` atomically.

- [ ] **Step 5: Wire Make and deterministic local configuration**

Add:

```make
docs-build:
	@bash $(DEPLOY_ROOT)/scripts/docs/build-release.sh

docs-publish: docs-build
	@bash $(DEPLOY_ROOT)/scripts/docs/publish-release.sh

local-docs:
	@DOCS_PUBLISH_ROOT="$(SOURCE_ROOT)/.generated/docs" $(MAKE) docs-publish
```

Make `local-bootstrap` depend on `local-docs`. Append this generated block to `gateway/quant-handler/config.local.yaml`:

```yaml
docs:
  root: "<absolute source root>/.generated/docs/current"
  privileged_user_ids: []
```

- [ ] **Step 6: Run release and local config tests**

Run: `cd hushine-deploy && bash scripts/docs-release.test.sh && bash scripts/local-configs.test.sh`

Expected: PASS.

- [ ] **Step 7: Commit deploy integration**

```bash
git add Makefile README.md scripts/docs scripts/docs-release.test.sh scripts/prepare-local-configs.py scripts/local-configs.test.sh
git commit -m "feat: publish immutable document releases"
```

### Task 4: Implement the verified `quant-handler` document store

**Files:**
- Create: `gateway/quant-handler/internal/docsstore/model.go`
- Create: `gateway/quant-handler/internal/docsstore/store.go`
- Test: `gateway/quant-handler/internal/docsstore/store_test.go`
- Modify: `gateway/quant-handler/internal/config/config.go`
- Modify: `gateway/quant-handler/internal/config/config_test.go`
- Modify: `gateway/quant-handler/config.yaml`

**Interfaces:**
- Produces:

```go
type AccessScope string
const ScopePublic AccessScope = "public"
const ScopePrivileged AccessScope = "privileged"

type Store struct { /* immutable snapshot cache */ }
func New(root string) *Store
func (s *Store) Manifest(scope AccessScope) (Manifest, error)
func (s *Store) SearchIndex(scope AccessScope) (SearchIndex, error)
func (s *Store) Document(scope AccessScope, id string) (DocumentContent, error)
func (s *Store) Asset(scope AccessScope, assetPath string) (Asset, error)
```

- [ ] **Step 1: Write failing store tests**

Use temporary release directories to cover valid load, checksum mismatch, missing package, duplicate document, public filtering, privileged visibility, hidden document 404 semantics, `../` traversal, symlink escape, asset MIME type, and atomic `current` switch.

- [ ] **Step 2: Run store tests and verify missing package**

Run: `cd gateway/quant-handler && go test ./internal/docsstore -run Test -count=1`

Expected: FAIL because `internal/docsstore` does not exist.

- [ ] **Step 3: Implement immutable snapshot loading**

Resolve `current` once per request, cache snapshots by resolved release directory, validate `schema_version == 1`, verify every SHA-256 before exposing the snapshot, and publish a snapshot only after all validation passes. A broken new symlink target returns `ErrUnavailable`; it must never mutate the previous verified cache entry.

- [ ] **Step 4: Implement scope filtering and safe assets**

Manifest and search index must be rebuilt from authorized documents rather than returning the raw release JSON. Document lookup first finds the ID in the filtered manifest. Asset lookup only succeeds when an authorized Markdown document references that normalized asset path.

- [ ] **Step 5: Add docs configuration**

Add:

```go
type DocsConfig struct {
    Root              string  `yaml:"root"`
    PrivilegedUserIDs []int64 `yaml:"privileged_user_ids"`
}
```

Environment overrides are exactly `DOCS_ROOT` and comma-separated `DOCS_PRIVILEGED_USER_IDS`. Invalid/non-positive IDs make configuration loading fail; removed aliases are not accepted.

- [ ] **Step 6: Run package and config tests**

Run: `cd gateway/quant-handler && go test ./internal/docsstore ./internal/config -count=1`

Expected: PASS.

- [ ] **Step 7: Commit store and configuration**

```bash
git add internal/docsstore internal/config config.yaml
git commit -m "feat: load verified document packages"
```

### Task 5: Expose authenticated document APIs

**Files:**
- Create: `gateway/quant-handler/internal/app/docs.go`
- Test: `gateway/quant-handler/internal/app/docs_test.go`
- Modify: `gateway/quant-handler/internal/app/app.go`
- Modify: `gateway/quant-handler/README.md`

**Interfaces:**
- Produces the four Phase 1 routes from the spec under `/api/docs/`.
- Uses JWT `uid`; privilege is derived only from configured IDs.

- [ ] **Step 1: Write failing handler tests**

Construct a `server` with a real temporary `docsstore.Store`. Cover GET-only methods, missing auth wrapper behavior, public manifest, privileged manifest, hidden document as 404, search-index filtering, Markdown content type, asset MIME/cache headers, ETag/304, and `DOCS_UNAVAILABLE` without affecting `/healthz`.

- [ ] **Step 2: Run focused tests and verify routes are absent**

Run: `cd gateway/quant-handler && go test ./internal/app -run 'TestDocs' -count=1`

Expected: FAIL because the docs handlers and fields do not exist.

- [ ] **Step 3: Implement privilege resolution and handlers**

Add these exact server members:

```go
docs               *docsstore.Store
docsPrivilegedUIDs map[int64]struct{}
```

Implement `docsScopeForUser(uid int64) docsstore.AccessScope` and `handleDocs(w, r)`. Split the remaining path only after `strings.TrimPrefix(r.URL.Path, "/api/docs/")`; decode exactly one document ID or normalized asset path and reject empty/malformed segments.

- [ ] **Step 4: Register routes without making docs startup-critical**

Construct `docsstore.New(cfg.Docs.Root)` even when the root is empty. Register:

```go
mux.HandleFunc("/api/docs/", s.cors(s.auth(http.HandlerFunc(s.handleDocs))).ServeHTTP)
```

Do not add docs readiness to `/healthz`; endpoint failures remain isolated.

- [ ] **Step 5: Run all handler tests and static checks**

Run: `cd gateway/quant-handler && go test ./... && go vet ./...`

Expected: PASS.

- [ ] **Step 6: Commit HTTP delivery**

```bash
git add internal/app README.md
git commit -m "feat: serve authorized document content"
```

### Task 6: Add real frontend tests, docs API, and deterministic search

**Files:**
- Modify: `gateway/quant-frontend/package.json`
- Modify: `gateway/quant-frontend/package-lock.json`
- Create: `gateway/quant-frontend/vitest.config.ts`
- Create: `gateway/quant-frontend/src/test/setup.ts`
- Create: `gateway/quant-frontend/src/api/docs.ts`
- Modify: `gateway/quant-frontend/src/api/client.ts`
- Create: `gateway/quant-frontend/src/features/docs/search.ts`
- Test: `gateway/quant-frontend/src/features/docs/search.test.ts`

**Interfaces:**
- Produces `getDocsManifest`, `getDocsSearchIndex`, `getDocsDocument`, and `docsAssetURL`.
- Produces `searchDocuments(index, query, limit): DocsSearchResult[]`.

- [ ] **Step 1: Install and configure the component test harness**

Add `vitest`, `jsdom`, `@testing-library/react`, `@testing-library/jest-dom`, and `@testing-library/user-event`. Add scripts:

```json
"test:unit": "vitest run",
"test:docs": "vitest run src/features/docs src/pages/DocumentationCenter.test.tsx"
```

The setup imports `@testing-library/jest-dom/vitest` and resets DOM/local storage after each test.

- [ ] **Step 2: Write failing API/search tests**

Assert Authorization headers and encoded IDs. Search cases must prove title beats keyword, keyword beats body, Chinese substring search works without whitespace tokenization, punctuation/case normalize consistently, empty query returns no results, and hidden documents cannot appear because the function only consumes the authorized index.

- [ ] **Step 3: Run tests and verify implementations are missing**

Run: `cd gateway/quant-frontend && npm run test:docs`

Expected: FAIL because `src/api/docs.ts` and `search.ts` do not exist.

- [ ] **Step 4: Implement the focused API client**

Export the existing `apiBase` and `parseErr` from `client.ts`; do not duplicate token/base/error behavior. Define strict response types matching Phase 1 JSON and use `encodeURIComponent(documentId)` for document requests.

- [ ] **Step 5: Implement deterministic search**

Normalize with `NFKC` and lowercase. Score exact title phrase `100`, title token `20`, keyword token `10`, and body token/substring `1`; sort by descending score, then manifest order, then document ID. Return a bounded snippet around the earliest match.

- [ ] **Step 6: Run tests and build**

Run: `cd gateway/quant-frontend && npm run test:docs && npm run build`

Expected: PASS.

- [ ] **Step 7: Commit client and search foundation**

```bash
git add package.json package-lock.json vitest.config.ts src/test src/api src/features/docs/search.ts src/features/docs/search.test.ts
git commit -m "test: add document portal client and search"
```

### Task 7: Build the responsive read-only documentation UI

**Files:**
- Create: `gateway/quant-frontend/src/features/docs/DocsNavigation.tsx`
- Create: `gateway/quant-frontend/src/features/docs/DocsSearch.tsx`
- Create: `gateway/quant-frontend/src/features/docs/DocsReader.tsx`
- Create: `gateway/quant-frontend/src/features/docs/docs.css`
- Create: `gateway/quant-frontend/src/pages/DocumentationCenter.tsx`
- Test: `gateway/quant-frontend/src/pages/DocumentationCenter.test.tsx`
- Modify: `gateway/quant-frontend/src/App.tsx`
- Modify: `gateway/quant-frontend/package.json`
- Modify: `gateway/quant-frontend/package-lock.json`
- Test: `gateway/quant-frontend/scripts/layout-shell.test.mjs`

**Interfaces:**
- Routes: `/docs` redirects to the first authorized document; `/docs/:documentId` renders it.
- Sidebar bottom entry label: `Documentation`, icon: `BookOpenText`.
- Desktop layout: directory, reader, Phase 2 assistant placeholder.

- [ ] **Step 1: Add Markdown dependencies and write failing component tests**

Add `react-markdown`, `remark-gfm`, `rehype-sanitize`, and `github-slugger`. Tests cover manifest load, first-document redirect, ordered navigation, search result navigation, previous/next links, loading/error/404 states, GFM table/code rendering, safe external links, blocked raw HTML, and mobile directory/assistant drawers.

- [ ] **Step 2: Extend the existing shell test before implementation**

Require `Documentation` to be in `.sidebar-bottom`, require protected `/docs` routes, and assert it is not added to `PRIMARY_NAV_ITEMS`.

- [ ] **Step 3: Run tests and verify the page is absent**

Run: `cd gateway/quant-frontend && npm run test:docs && node scripts/layout-shell.test.mjs`

Expected: FAIL because the page and route do not exist.

- [ ] **Step 4: Implement safe Markdown rendering**

`DocsReader` passes Markdown through `remark-gfm` and `rehype-sanitize`, generates stable heading IDs with `github-slugger`, renders code with language classes, rewrites manifest asset links through `docsAssetURL`, and adds `target="_blank" rel="noreferrer"` only to external HTTP(S) links. Raw HTML remains text/removed.

- [ ] **Step 5: Implement page state and navigation**

Fetch manifest and authorized search index once per `docs_commit`. Abort obsolete document requests on navigation. A search keystroke only calls `searchDocuments`; it must never issue a POST. Show the right column as a clearly disabled “Ask Codex — configure in Phase 2” panel rather than a fake input.

- [ ] **Step 6: Implement responsive visual design**

Use existing 640px/1024px breakpoints only. At desktop use `260px minmax(0,1fr) 340px`; at tablet collapse the assistant to a drawer; at mobile collapse both directory and assistant. Keep article measure at `78ch`, code blocks horizontally scrollable, tables wrapped, focus outlines visible, and colors compatible with the existing light shell.

- [ ] **Step 7: Register the bottom navigation entry and routes**

Put the authenticated `Documentation` NavLink in `.sidebar-bottom` above the unauthenticated login entry. Preserve collapsed tooltip and drawer close behavior.

- [ ] **Step 8: Run all frontend tests and build**

Run: `cd gateway/quant-frontend && npm run test:unit && for test in scripts/*.test.mjs; do node "$test"; done && npm run build`

Expected: PASS.

- [ ] **Step 9: Commit the portal UI**

```bash
git add src package.json package-lock.json scripts/layout-shell.test.mjs
git commit -m "feat: add read-only documentation center"
```

### Task 8: Complete cross-repository Phase 1 acceptance

**Files:**
- Modify: `hushine-deploy/docs/README.md`
- Modify: `hushine-deploy/docs/operations/local-development.md`
- Create: `hushine-deploy/scripts/docs-portal-smoke.sh`
- Create: `hushine-deploy/docs/test-reports/2026-08-31-document-center-phase-1.md`

**Interfaces:**
- Produces a repeatable authenticated smoke that proves public/privileged filtering and browser usability.

- [ ] **Step 1: Write the failing smoke contract**

The smoke must start from a freshly built package, launch quant-handler with a temporary JWT user fixture or test server, and verify manifest/search/document/assets for one public and one privileged user. It must then run the frontend component suite and production build.

- [ ] **Step 2: Run the smoke and verify missing acceptance wiring**

Run: `cd hushine-deploy && bash scripts/docs-portal-smoke.sh`

Expected: FAIL until all Phase 1 repositories are integrated.

- [ ] **Step 3: Update current documentation ownership**

Change `hushine-deploy/docs/README.md` from the current-document index to an operator transition page that identifies `hushine-docs` as canonical. Do not delete migration source files until every migrated page has the same or newer verified content and the portal smoke passes; then remove duplicate current pages in a separate, clearly reviewed commit.

- [ ] **Step 4: Run full verification**

Run:

```bash
cd hushine-docs && npm test
cd ../gateway/quant-handler && go test ./... && go vet ./...
cd ../quant-frontend && npm run test:unit && for test in scripts/*.test.mjs; do node "$test"; done && npm run build
cd ../../hushine-deploy && bash scripts/docs-release.test.sh && bash scripts/docs-portal-smoke.sh
```

Expected: every command PASS; the report records exact commits and release hashes.

- [ ] **Step 5: Verify the real local page visually**

Run `make local-docs local-start`, log in, open `/docs`, and verify desktop plus a 390px viewport: directory order, search snippets, GFM tables/code, previous/next navigation, collapsed sidebar tooltip, and disabled Phase 2 assistant. Capture screenshots in the test report.

- [ ] **Step 6: Commit Phase 1 acceptance evidence**

```bash
git add docs scripts/docs-portal-smoke.sh
git commit -m "test: verify document center phase one"
```

- [ ] **Step 7: Publish the new independent repository**

After all local commits pass, create the private `hushine-tech/hushine-docs` GitHub repository from the local `hushine-docs` repository, add `origin`, and push `main`. Record the remote URL and pushed commit in the Phase 1 report; do not push any generated release directory.
