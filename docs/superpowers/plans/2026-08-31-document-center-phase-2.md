# Document Center Phase 2 Implementation Plan

> Superseded provider/persistence design: follow
> [2026-09-05 Codex CLI correction](../specs/2026-09-05-document-assistant-cli-correction.md).
> The API-key HTTP provider described below is historical and has been removed.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a single persistent per-user browser Conversation that answers from the authorized document package and exact deployed source code, restores history after reopening, and returns verifiable citations.

**Architecture:** `hushine-deploy` builds a secret-safe source index tied to the same deployment manifest as Phase 1. `quant-handler` owns OpenAI Conversations/Responses calls, validates Conversation metadata against JWT user, docs commit, and access scope, and exposes only read-only `search_docs`/`search_source` tools. `quant-frontend` stores one Conversation ID per user in `localStorage`, restores messages on entry, and replaces that ID when the user clicks “开始新会话”.

**Tech Stack:** Go 1.26 standard `net/http` OpenAI client and HMAC-SHA256 identity binding, OpenAI Conversations and Responses APIs, React 19 + TypeScript, existing Node/Vitest frontend tests, Python/Node release index builders, local fake OpenAI HTTP server for deterministic acceptance.

**Spec:** `hushine-deploy/docs/superpowers/specs/2026-08-31-document-center-design.md`

## Global Constraints

- Phase 1 must be complete and its package interfaces are consumed unchanged.
- The browser never receives `OPENAI_API_KEY`, developer instructions, raw source-index files, or unrestricted filesystem access.
- One browser profile stores one Conversation ID per Hushine user at `hushine.docsConversation.<user_id>`.
- Hushine does not add a conversation/history database table. OpenAI Conversation is the only persistent message store.
- Every Conversation metadata record contains service-generated `hushine_uid_hash`, exact `docs_commit`, and `access_scope`.
- Conversation IDs from the browser are untrusted. Identity, docs version, and scope are validated before listing messages or asking a question.
- No application turn count or idle timeout is introduced. Official context management may compact old model context without changing the product Conversation ID.
- “开始新会话” creates and stores a new Conversation ID. It does not claim immediate deletion of OpenAI-retained items.
- Ordinary users can search/ask only public docs. Privileged users can additionally search operations/internal docs and the exact deployed source index.
- Answers without citations that match actual retrieval results fail closed with `DOCS_ANSWER_UNVERIFIED`.
- The model receives only `search_docs` and, for privileged users, `search_source`. It receives no shell, network, database, order, or arbitrary file tool.
- OpenAI failure disables only Ask Codex; Phase 1 reading and local search remain usable.

---

## File Structure

### `hushine-deploy`

- `scripts/docs/source-index.py` — whitelist, chunk, and line-map exact deployed source files.
- `scripts/docs/source-index.test.py` — secret exclusion, deterministic chunk, commit, and line tests.
- `scripts/docs/build-release.sh` — include `source-index.json` for the same deployment manifest.
- `scripts/docs-assistant-smoke.sh` — fake-OpenAI end-to-end acceptance.

### `gateway/quant-handler`

- `internal/openai/client.go` — small standard-library Conversations/Responses HTTP client.
- `internal/openai/client_test.go` — exact request/response/error contracts against `httptest.Server`.
- `internal/docsassistant/model.go` — conversation, message, citation, retrieval, and typed error DTOs.
- `internal/docsassistant/identity.go` — stable HMAC user binding and metadata validation.
- `internal/docsassistant/index.go` — authorized docs/source lexical lookup.
- `internal/docsassistant/assistant.go` — tool-call loop, context management, citation verification.
- `internal/docsassistant/*_test.go` — identity, retrieval, tools, citations, and failure tests.
- `internal/app/docs_conversations.go` and tests — create/list/ask endpoints.
- `internal/config/config.go`, tests, `config.yaml` — OpenAI and assistant configuration.
- `internal/app/app.go` — assistant construction and route registration.

### `gateway/quant-frontend`

- `src/api/docs.ts` — Conversation types and create/get/ask calls.
- `src/features/docs/conversationStorage.ts` and tests — exact per-user localStorage behavior.
- `src/features/docs/DocsAssistant.tsx` and tests — restored transcript, ask, citations, retry, reset.
- `src/pages/DocumentationCenter.tsx` and tests — replace Phase 1 placeholder with active assistant.
- `src/features/docs/docs.css` — assistant states and responsive drawer.

---

### Task 1: Build a deterministic, secret-safe deployed source index

**Files:**
- Create: `hushine-deploy/scripts/docs/source-index.py`
- Test: `hushine-deploy/scripts/docs/source-index.test.py`
- Modify: `hushine-deploy/scripts/docs/build-release.sh`
- Modify: `hushine-deploy/scripts/docs-release.test.sh`

**Interfaces:**
- Consumes: the exact deployment manifest from Phase 1 and repository paths under `SOURCE_ROOT`.
- Produces: `source-index.json` inside the immutable document release.

- [ ] **Step 1: Write failing source-index tests**

Create fixture repos containing safe code, generated code, `.env`, PEM/private keys, logs, user strategy source, coverage output, symlink escapes, and Unicode. Assert only allowed files are indexed and every chunk has exact repository, commit, path, start/end line, language, symbol hints, and SHA-256.

```python
self.assertEqual(chunk["repository"], "strategy-service")
self.assertEqual(chunk["commit"], fixture_commit)
self.assertEqual(chunk["start_line"], 1)
self.assertGreaterEqual(chunk["end_line"], chunk["start_line"])
self.assertNotIn("api-secret", json.dumps(index))
```

- [ ] **Step 2: Run the tests and verify the builder is absent**

Run: `cd hushine-deploy && python3 -m unittest scripts/docs/source-index.test.py -v`

Expected: FAIL because `source-index.py` does not exist.

- [ ] **Step 3: Implement exact allow/deny policy**

Allowed suffixes are exactly `.go`, `.proto`, `.py`, `.ts`, `.tsx`, `.sql`, `.yaml`, `.yml`, and `.md`. Always exclude `.git`, `node_modules`, `vendor`, `.venv`, `dist`, `build`, generated protobuf directories, logs, coverage, `.env*`, certificate/key suffixes, local config files, fixtures marked secret, and paths containing user strategy uploads.

Reject every symlink whose resolved target is outside its repository. Read each file only from the commit recorded in the deployment manifest by using `git show <commit>:<path>`; never index an uncommitted working-tree version.

- [ ] **Step 4: Implement stable chunking and symbol hints**

Chunk at logical blank-line boundaries with a target of 120 lines and hard maximum of 180 lines, overlapping the previous 12 lines. Extract Go/Python/TypeScript/proto declaration names with conservative regular expressions and store them as search hints. Sort chunks by repository, path, start line.

Output shape:

```json
{
  "schema_version": 1,
  "deployment_digest": "<sha256>",
  "chunks": [{
    "id": "<sha256 repository/path/start/end>",
    "repository": "core-service",
    "commit": "<40 hex>",
    "path": "internal/wallet/futures.go",
    "start_line": 1,
    "end_line": 120,
    "language": "go",
    "symbols": ["AvailableBalance"],
    "text": "...",
    "sha256": "<64 hex>"
  }]
}
```

- [ ] **Step 5: Include and verify the source index in the release**

Phase 1 release building invokes the source indexer after the docs package succeeds. Add its checksum and schema version to `manifest.json`. A source-index failure prevents publication; there is no docs-only silent fallback when `DOCS_CHAT_ENABLED=true`.

- [ ] **Step 6: Run release tests**

Run: `cd hushine-deploy && python3 -m unittest scripts/docs/source-index.test.py -v && bash scripts/docs-release.test.sh`

Expected: PASS.

- [ ] **Step 7: Commit source indexing**

```bash
git add scripts/docs scripts/docs-release.test.sh
git commit -m "feat: index exact deployed source for docs assistant"
```

### Task 2: Implement a narrow OpenAI Conversations/Responses client

**Files:**
- Create: `gateway/quant-handler/internal/openai/client.go`
- Test: `gateway/quant-handler/internal/openai/client_test.go`
- Modify: `gateway/quant-handler/internal/config/config.go`
- Modify: `gateway/quant-handler/internal/config/config_test.go`
- Modify: `gateway/quant-handler/config.yaml`

**Interfaces:**
- Produces:

```go
type Client interface {
    CreateConversation(ctx context.Context, metadata map[string]string) (Conversation, error)
    RetrieveConversation(ctx context.Context, id string) (Conversation, error)
    ListConversationItems(ctx context.Context, id string) ([]Item, error)
    CreateResponse(ctx context.Context, req ResponseRequest) (Response, error)
}

type ResponseRequest struct {
    Model             string
    ConversationID    string
    Instructions      string
    Input             []InputItem
    Tools             []Tool
    ToolOutputs       []ToolOutput
    ContextManagement []ContextManagement
}
```

- [ ] **Step 1: Write failing HTTP client contract tests**

Use `httptest.Server` to assert exact paths and Bearer authorization for:

```text
POST /v1/conversations
GET  /v1/conversations/{id}
GET  /v1/conversations/{id}/items?order=asc&limit=100
POST /v1/responses
```

Cover pagination, structured output, function calls, 400, 401, 404, 429 with Retry-After, 500, timeout, malformed JSON, and response body size limits. Test logs/errors never include the API key or full upstream body.

- [ ] **Step 2: Run focused tests and verify the client is absent**

Run: `cd gateway/quant-handler && go test ./internal/openai -count=1`

Expected: FAIL because the package does not exist.

- [ ] **Step 3: Implement the standard-library client**

Use one injected `*http.Client`, base URL, and API key. Escape all path IDs with `url.PathEscape`, cap response bodies, and classify errors:

```go
var ErrNotFound = errors.New("openai resource not found")
type RateLimitError struct { RetryAfter time.Duration }
type UpstreamError struct { Status int; RequestID string }
```

Never return raw upstream JSON in error strings.

- [ ] **Step 4: Add assistant configuration**

Add:

```go
type DocsAssistantConfig struct {
    Enabled           bool   `yaml:"enabled"`
    APIKey            string `yaml:"-"`
    BaseURL           string `yaml:"base_url"`
    Model             string `yaml:"model"`
    RequestsPerMinute int    `yaml:"requests_per_minute"`
}
```

Environment names are exactly `DOCS_CHAT_ENABLED`, `OPENAI_API_KEY`, `OPENAI_BASE_URL`, `OPENAI_DOCS_MODEL`, and `DOCS_CHAT_REQUESTS_PER_MINUTE`. `OPENAI_API_KEY` is environment-only and YAML input named `api_key` is rejected as an unknown field. Enabling chat requires non-empty key/model and a positive rate; disabled chat starts without them.

- [ ] **Step 5: Run package/config tests and vet**

Run: `cd gateway/quant-handler && go test ./internal/openai ./internal/config -count=1 && go vet ./internal/openai ./internal/config`

Expected: PASS.

- [ ] **Step 6: Commit client and configuration**

```bash
git add internal/openai internal/config config.yaml
git commit -m "feat: add docs assistant OpenAI client"
```

### Task 3: Bind Conversation identity and restore messages safely

**Files:**
- Create: `gateway/quant-handler/internal/docsassistant/model.go`
- Create: `gateway/quant-handler/internal/docsassistant/identity.go`
- Test: `gateway/quant-handler/internal/docsassistant/identity_test.go`
- Create: `gateway/quant-handler/internal/app/docs_conversations.go`
- Test: `gateway/quant-handler/internal/app/docs_conversations_test.go`
- Modify: `gateway/quant-handler/internal/app/app.go`

**Interfaces:**
- Routes: `POST /api/docs/conversations`, `GET /api/docs/conversations/{id}`.
- Metadata keys: `hushine_uid_hash`, `docs_commit`, `access_scope`.

- [ ] **Step 1: Write failing HMAC and route tests**

Assert the user hash is stable for the same secret/UID, differs by UID and secret, contains no raw UID, and uses constant-time comparison. Handler tests cover create, list, modified ID, other user, scope downgrade/upgrade, stale docs commit, upstream not found, malformed item, and assistant message citation restoration.

- [ ] **Step 2: Run tests and verify missing assistant types**

Run: `cd gateway/quant-handler && go test ./internal/docsassistant ./internal/app -run 'TestDocsConversation|TestConversationIdentity' -count=1`

Expected: FAIL because identity and handlers do not exist.

- [ ] **Step 3: Implement exact identity functions**

```go
func UserHash(secret []byte, userID int64) string
func ConversationMetadata(secret []byte, userID int64, docsCommit string, scope docsstore.AccessScope) map[string]string
func ValidateConversationMetadata(meta map[string]string, secret []byte, userID int64, docsCommit string, scope docsstore.AccessScope) error
```

Use HMAC-SHA256 over `docs-conversation:v1:<uid>` and `subtle.ConstantTimeCompare`.

Pass the existing configured JWT signing secret as `secret`; the fixed `docs-conversation:v1:` prefix provides purpose separation. A JWT-secret rotation intentionally makes prior Conversation metadata stale rather than adding another persistent identity secret.

- [ ] **Step 4: Implement create/list routes**

`POST` derives current verified docs snapshot and scope, creates an OpenAI Conversation with exact metadata, and returns ID/docs commit/scope. `GET` first retrieves and validates Conversation metadata, then lists all items with pagination and converts only user/assistant messages. Ignore tool internals in UI history; parse assistant structured JSON into answer/citations and reject invalid citation shapes.

- [ ] **Step 5: Register routes only when the assistant service exists**

Keep endpoints registered when chat is disabled so they return structured `DOCS_CHAT_UNAVAILABLE`; do not make server startup or health depend on OpenAI connectivity.

- [ ] **Step 6: Run all handler tests**

Run: `cd gateway/quant-handler && go test ./... && go vet ./...`

Expected: PASS.

- [ ] **Step 7: Commit Conversation identity and restoration**

```bash
git add internal/docsassistant internal/app
git commit -m "feat: create and restore authorized docs conversations"
```

### Task 4: Implement authorized document/source retrieval and citation verification

**Files:**
- Create: `gateway/quant-handler/internal/docsassistant/index.go`
- Create: `gateway/quant-handler/internal/docsassistant/assistant.go`
- Test: `gateway/quant-handler/internal/docsassistant/index_test.go`
- Test: `gateway/quant-handler/internal/docsassistant/assistant_test.go`
- Modify: `gateway/quant-handler/internal/docsstore/store.go`

**Interfaces:**
- Produces:

```go
type Retriever interface {
    SearchDocs(scope docsstore.AccessScope, query string, limit int) ([]SearchHit, error)
    SearchSource(scope docsstore.AccessScope, query string, limit int) ([]SearchHit, error)
}

func (a *Assistant) Ask(ctx context.Context, userID int64, scope docsstore.AccessScope,
    conversationID, question, currentDocumentID string) (Answer, error)
```

- [ ] **Step 1: Write failing retrieval tests**

Cover public/privileged docs, privileged-only source, Chinese questions with model-generated English identifiers, exact symbol/path ranking, line preservation, malformed source index, result limits, and zero-result behavior. Public scope calling `SearchSource` must return `ErrForbidden`, not an empty success.

- [ ] **Step 2: Write failing assistant tool-loop tests**

Fake OpenAI returns: direct answer without retrieval, `search_docs`, privileged `search_source`, repeated tool call, unknown tool, more than four tool rounds, citation outside returned hits, no citation, upstream failure, and a valid structured answer. Only the final valid case succeeds.

Also assert every Responses request enables the official context-management compaction behavior, including after a fixture Conversation exceeds the normal prompt window; compaction must not replace the product Conversation ID.

- [ ] **Step 3: Run tests and verify retrieval is absent**

Run: `cd gateway/quant-handler && go test ./internal/docsassistant -run 'TestIndex|TestAssistant' -count=1`

Expected: FAIL.

- [ ] **Step 4: Implement local index search**

Load `search-index.json` and `source-index.json` from the same verified release snapshot. Normalize NFKC/lowercase; score exact symbol `100`, path/title `30`, symbol/keyword token `20`, and body token `1`. Return at most eight hits per call and at most 24,000 total characters.

- [ ] **Step 5: Implement the constrained tool loop**

Developer instructions require retrieval before factual claims, citations from returned hit IDs, explicit uncertainty when no hit exists, and output matching:

```json
{"answer":"...","citations":[{"hit_id":"...","anchor":"..."}]}
```

Expose `search_docs` to both scopes and `search_source` only to privileged scope. Execute at most four tool rounds and eight total tool calls. Feed tool results as compact JSON containing hit ID, title/repository, path/document ID, commit, line range, and text.

- [ ] **Step 6: Verify citations against actual hits**

Convert hit IDs to public `document` or `source` citations only after exact lookup in the accumulated tool-result set. Reject missing/duplicate-invalid IDs, commit mismatch, line ranges outside the hit, or source citations in public scope with `ErrAnswerUnverified`.

- [ ] **Step 7: Run assistant tests and race detector**

Run: `cd gateway/quant-handler && go test -race ./internal/docsassistant -count=1`

Expected: PASS.

- [ ] **Step 8: Commit retrieval and orchestration**

```bash
git add internal/docsassistant internal/docsstore
git commit -m "feat: answer docs questions from verified source"
```

### Task 5: Expose ask semantics, rate limiting, and safe retry behavior

**Files:**
- Modify: `gateway/quant-handler/internal/app/docs_conversations.go`
- Modify: `gateway/quant-handler/internal/app/docs_conversations_test.go`
- Create: `gateway/quant-handler/internal/app/docs_rate_limit.go`
- Test: `gateway/quant-handler/internal/app/docs_rate_limit_test.go`
- Modify: `gateway/quant-handler/README.md`

**Interfaces:**
- Route: `POST /api/docs/conversations/{conversation_id}/messages`.
- Typed errors: `DOCS_CHAT_UNAVAILABLE`, `DOCS_CONVERSATION_STALE`, `DOCS_RATE_LIMITED`, `DOCS_ANSWER_UNVERIFIED`.

- [ ] **Step 1: Write failing ask/rate tests**

Cover empty/oversized question, inaccessible current document, stale metadata before OpenAI call, normal answer, 429/Retry-After, timeout, unverified answer, per-user independent buckets, and disabled feature. Assert Phase 1 GET routes still work for every error.

- [ ] **Step 2: Run focused tests and verify route behavior is absent**

Run: `cd gateway/quant-handler && go test ./internal/app -run 'TestDocsAsk|TestDocsRate' -count=1`

Expected: FAIL.

- [ ] **Step 3: Implement bounded per-user token buckets**

Use an injected clock, one bucket per authenticated UID, configured requests/minute, maximum map size with idle eviction, and no IP-only identity. Return HTTP 429 with integer `Retry-After` and structured error code.

- [ ] **Step 4: Implement ask handler**

Validate Conversation metadata and current document before consuming a rate token or calling OpenAI. On stale metadata return 409 without appending the question. On upstream uncertainty do not automatically resubmit; the frontend keeps the unsent/failed question for explicit retry.

Reject questions whose trimmed UTF-8 text is empty or exceeds 8,000 Unicode code points before rate limiting or upstream calls.

- [ ] **Step 5: Run all handler verification**

Run: `cd gateway/quant-handler && go test -race ./... && go vet ./...`

Expected: PASS.

- [ ] **Step 6: Commit the public ask API**

```bash
git add internal/app README.md
git commit -m "feat: expose rate-limited docs conversation answers"
```

### Task 6: Persist one Conversation ID per user in the frontend

**Files:**
- Modify: `gateway/quant-frontend/src/api/docs.ts`
- Create: `gateway/quant-frontend/src/features/docs/conversationStorage.ts`
- Test: `gateway/quant-frontend/src/features/docs/conversationStorage.test.ts`

**Interfaces:**
- Produces:

```ts
export function docsConversationStorageKey(userId: number): string;
export function loadDocsConversationID(userId: number): string | null;
export function saveDocsConversationID(userId: number, conversationId: string): void;
export function clearDocsConversationID(userId: number): void;

export async function createDocsConversation(): Promise<DocsConversation>;
export async function getDocsConversation(id: string): Promise<DocsConversationHistory>;
export async function askDocsConversation(id: string, question: string, currentDocumentId: string): Promise<DocsAnswer>;
```

- [ ] **Step 1: Write failing storage/API tests**

Assert exact key `hushine.docsConversation.<user_id>`, reject non-positive user IDs and IDs not matching `^conv_[A-Za-z0-9_-]+$`, isolate two users, survive module reload, clear one user only, encode route IDs, and parse `DOCS_CONVERSATION_STALE` distinctly.

- [ ] **Step 2: Run tests and verify modules are absent**

Run: `cd gateway/quant-frontend && npm run test:docs -- src/features/docs/conversationStorage.test.ts`

Expected: FAIL.

- [ ] **Step 3: Implement localStorage wrapper and API calls**

Never store messages, API keys, access scope overrides, developer prompts, or source snippets locally. Treat the ID as an opaque locator and let the backend authorize it. Corrupt IDs are removed before any request.

- [ ] **Step 4: Run focused tests and build**

Run: `cd gateway/quant-frontend && npm run test:docs && npm run build`

Expected: PASS.

- [ ] **Step 5: Commit persistent locator support**

```bash
git add src/api/docs.ts src/features/docs/conversationStorage.ts src/features/docs/conversationStorage.test.ts
git commit -m "feat: persist the active docs conversation locator"
```

### Task 7: Build the Conversation UI, restoration, citations, and reset button

**Files:**
- Create: `gateway/quant-frontend/src/features/docs/DocsAssistant.tsx`
- Test: `gateway/quant-frontend/src/features/docs/DocsAssistant.test.tsx`
- Modify: `gateway/quant-frontend/src/pages/DocumentationCenter.tsx`
- Modify: `gateway/quant-frontend/src/pages/DocumentationCenter.test.tsx`
- Modify: `gateway/quant-frontend/src/features/docs/docs.css`

**Interfaces:**
- Replaces Phase 1 placeholder while preserving the same desktop/mobile panel boundary.
- Button accessible name: `开始新会话`; send button: `让 Codex 回答`.

- [ ] **Step 1: Write failing component tests**

Cover first-open create/save, existing-ID restore, message/citation display, send to same ID, current document change, stale ID auto-create before resend, user-visible 429 retry time, upstream failure with manual retry, loading cancellation on unmount, reset replacement, user switch, privileged source citation, and mobile assistant drawer.

- [ ] **Step 2: Run the tests and verify the placeholder remains**

Run: `cd gateway/quant-frontend && npm run test:docs -- src/features/docs/DocsAssistant.test.tsx src/pages/DocumentationCenter.test.tsx`

Expected: FAIL.

- [ ] **Step 3: Implement restoration and single-flight creation**

On mount, load the current authenticated user ID, read localStorage, and retrieve that Conversation. If absent/stale/not found, create exactly one Conversation even under React StrictMode double effects, then save it. Render restored items in API order.

- [ ] **Step 4: Implement ask and citation UI**

Disable send while a request is active. Append the user message optimistically, replace it with failed/retry state on error, and append the returned answer once. Document citations navigate inside `/docs`; source citations show repository/path/commit/line without exposing raw index downloads.

- [ ] **Step 5: Implement “开始新会话”**

Require one confirmation only when a request is active; otherwise create immediately. Save the new ID before clearing old rendered messages so reload cannot restore the old one. If creation fails, preserve the current Conversation and messages.

- [ ] **Step 6: Preserve explicit search-vs-model behavior**

Typing in the Phase 1 search box never focuses or submits the assistant. Only `让 Codex 回答` sends a model request. Prefill the assistant question from search only after the user clicks the explicit Ask Codex action.

- [ ] **Step 7: Run all frontend verification**

Run: `cd gateway/quant-frontend && npm run test:unit && for test in scripts/*.test.mjs; do node "$test"; done && npm run build`

Expected: PASS.

- [ ] **Step 8: Commit the assistant UI**

```bash
git add src/features/docs src/pages/DocumentationCenter.tsx src/pages/DocumentationCenter.test.tsx
git commit -m "feat: add persistent source-aware docs assistant"
```

### Task 8: Deploy, smoke, and review the complete document center

**Files:**
- Modify: `hushine-deploy/scripts/prepare-local-configs.py`
- Modify: `hushine-deploy/scripts/prepare-remote-configs.py`
- Modify: `hushine-deploy/scripts/local-configs.test.sh`
- Create: `hushine-deploy/scripts/docs-assistant-smoke.sh`
- Create: `hushine-deploy/docs/test-reports/2026-08-31-document-center-phase-2.md`
- Modify: `hushine-deploy/docs/operations/local-development.md`
- Modify: `hushine-deploy/docs/production-deploy-checklist.md`

**Interfaces:**
- Local smoke uses `OPENAI_BASE_URL` pointed at a deterministic fake server; real API use remains an explicit environment configuration.

- [ ] **Step 1: Write a fake OpenAI server and failing system smoke**

The smoke fake must implement create/retrieve/list Conversation and Responses tool-call rounds. It records metadata and rejects mismatched IDs. The system smoke logs in as public and privileged fixtures, asks one docs-only and one source-only question, reloads the page/API history, resets the Conversation, and checks citations.

- [ ] **Step 2: Run the smoke and verify deployment wiring is missing**

Run: `cd hushine-deploy && bash scripts/docs-assistant-smoke.sh`

Expected: FAIL until chat configuration and all endpoints are wired.

- [ ] **Step 3: Add local/remote configuration without secrets in files**

Generated checked/local YAML may include `enabled`, base URL, model, and rate but never the API key. `OPENAI_API_KEY` is supplied only through the quant-handler process environment. `scripts/prepare-remote-configs.py` preserves the same rule.

- [ ] **Step 4: Run full automated verification**

Run:

```bash
cd hushine-deploy && python3 -m unittest scripts/docs/source-index.test.py -v
cd ../gateway/quant-handler && go test -race ./... && go vet ./...
cd ../quant-frontend && npm run test:unit && for test in scripts/*.test.mjs; do node "$test"; done && npm run build
cd ../../hushine-deploy && bash scripts/docs-release.test.sh && bash scripts/docs-assistant-smoke.sh
```

Expected: PASS with the fake OpenAI endpoint; no real API key is required for CI.

- [ ] **Step 5: Perform real-page acceptance**

Start the local stack, log in, open `/docs`, verify search does not call the assistant, ask a docs question, reload and restore, ask a privileged source question, verify citations against exact local commits/lines, click “开始新会话”, and verify localStorage holds the new ID. Confirm another user cannot use the copied ID and a rebuilt docs package invalidates the old Conversation.

- [ ] **Step 6: Review security and data boundaries**

Inspect browser storage/network/logs: only Conversation ID is local; no API key, developer prompt, hidden search result, source-index JSON, or raw unauthorized snippet appears. Confirm docs/search stay available with the fake OpenAI server stopped.

- [ ] **Step 7: Record evidence and commit deployment acceptance**

The report records all repository commits, docs/source index hashes, fake-server cases, page screenshots, and remaining operational requirement to provide a real `OPENAI_API_KEY`.

```bash
git add scripts docs
git commit -m "test: verify persistent document conversations"
```

### Task 9: Final branch review and remote delivery

**Files:**
- No new implementation files; this task verifies and delivers owned commits.

**Interfaces:**
- Produces pushed commits for `hushine-docs`, `hushine-deploy`, `quant-handler`, and `quant-frontend` on their feature branches.

- [ ] **Step 1: Run repository-scoped status and diff review**

For each repository, verify `git status --short`, `git diff <baseline>...HEAD --check`, generated-file exclusions, no unrelated user changes staged, and commit messages match the task boundaries.

- [ ] **Step 2: Run the complete Phase 1 + Phase 2 verification once more**

Use the exact commands from Task 8 Step 4, plus `hushine-docs npm test`. Do not reuse earlier output when claiming completion.

- [ ] **Step 3: Review implementation against every spec completion criterion**

Map each criterion to a passing test or page acceptance artifact. Any criterion without evidence blocks delivery.

- [ ] **Step 4: Push the owning feature branches**

Push only after fresh verification. Record branch names and remote commit SHAs in the Phase 2 report. Do not merge or delete worktrees without a separate integration decision.
