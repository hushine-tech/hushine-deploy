# Document Center Phase 1 Acceptance

Date: 2026-08-31

## Outcome

The read-only document center is integrated across the independent document source,
release tooling, authenticated HTTP boundary, and Portal. The automated acceptance
gates pass. An independent code review reports no Critical or Important findings.

The only remaining acceptance activities requiring user-owned external state are:

- authenticated visual capture in the in-app browser;
- creation of the private `hushine-tech/hushine-docs` GitHub repository and first push.

Neither activity changes the implemented runtime contract.

## Accepted source identities

| Repository | Commit | Purpose |
| --- | --- | --- |
| `hushine-docs` | `e945f817f1d933d3b9d28c414cd7c9303ba261dc` | canonical Markdown, assets, deterministic builder |
| `hushine-deploy` | `4ebf4df449ec1040c43ce2ba1b96a2e8c8812ec5` | release/publish flow and cross-repository smoke |
| `quant-handler` | `a644079ed24201510884fac085f50ab0cd86435b` | verified store, authenticated APIs, commit-pinned content |
| `quant-frontend` | `0d5cd3250bb61b4ee680ef9983e28b60aa5b5195` | local search, safe Markdown, responsive document UI |

The fresh acceptance package contains 15 documents in three ordered sections. Its
identity and top-level hashes are:

```text
docs_commit:       e945f817f1d933d3b9d28c414cd7c9303ba261dc
manifest.json:     675ce8e2dd3763f6dacdce86202b89ffd9b680c26b07251916658b7275b17a61
search-index.json: c41a01fdd9dd54e348edacd6d4d8039381b431fcf34243460b75fd154de1b9ed
```

The acceptance package was generated under `.generated/docs-acceptance-build`,
which is ignored and is not committed. `ALLOW_DIRTY_DOCS_RELEASE=true` was used only
for this local acceptance build because unrelated pre-existing user changes remain
in `scraper` and `strategy-service`. The package manifest records Git commits, never
dirty content. This build is evidence, not production release authorization.

## Automated verification

| Gate | Result |
| --- | --- |
| `hushine-docs` package/corpus tests | PASS — 21 tests |
| reproducible build, checksum, link, path, and secret-exclusion policies | PASS |
| `quant-handler` complete Go suite | PASS |
| `quant-handler` `go vet ./...` | PASS |
| document scope, traversal, checksum, ETag, and atomic-switch tests | PASS |
| manifest-pinned document and asset requests across a release switch | PASS |
| `quant-frontend` Vitest suite | PASS — 19 tests |
| existing frontend shell contracts | PASS — 48 scripts |
| TypeScript and production Vite build | PASS |
| document release and atomic publication contract | PASS |
| generated local-config contract | PASS |
| fresh-package public/privileged cross-repository smoke | PASS |
| independent post-implementation review | PASS — ready to merge |

The Vite build continues to report the pre-existing main-chunk size warning
(`index` about 733 kB). The document page is lazy-loaded into its own approximately
188 kB chunk, so this phase does not add document dependencies to the initial route.

## Behavior verified by focused tests

- ordinary and privileged users receive independently filtered manifest, search,
  document, and asset surfaces;
- every document and asset request is pinned to the manifest `docs_commit`, so an
  atomic publication cannot combine one release's navigation with another release's
  body or image;
- search is deterministic and displays section, summary, and matched context without
  issuing a server request per keystroke;
- Markdown uses registered authenticated assets, sanitized GFM, stable heading IDs,
  explicit external-link behavior, breadcrumbs, and direct heading fragments;
- mobile directory and assistant drawers restore focus, trap keyboard focus while
  modal, close on Escape, lock body scroll, and release all modal state across the
  640 px and 1024 px responsive breakpoints;
- package and document failures are isolated from the trading application and expose
  explicit retry actions;
- Phase 2 Ask Codex controls remain disabled and send no model request.

## Visual acceptance status

The local package was published and the updated `quant-handler` was restarted. Health
returned HTTP 200. Opening `/docs` in a fresh in-app browser correctly redirected to
`/login`; no credential was entered during automated acceptance. Desktop and 390 px
screenshots therefore remain pending an authenticated browser session. No screenshot
is attached to this report to avoid presenting the login screen as product evidence.

## Remote publication status

The local `hushine-docs` repository is complete on `main` and has no generated release
directory tracked. This machine does not currently have a GitHub CLI or configured
`origin`, so no remote repository was created and no push was attempted.
