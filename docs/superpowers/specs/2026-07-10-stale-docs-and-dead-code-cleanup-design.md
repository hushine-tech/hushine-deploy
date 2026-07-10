# Hushine 过时文档与废弃代码保守清理设计

## 背景

Hushine 当前工作区由多个独立 Git 仓库组成，根目录本身不是 Git 仓库。当前多个子仓库存在用户未提交修改，尤其是 `control-panel-service`、`gateway/quant-handler`、`gateway/quant-frontend`、`strategy-service` 和 `hushine-deploy/restart.sh`。本次清理必须保留这些修改，不得以重置、覆盖生成文件或整文件替换的方式消除用户工作。

当前产品功能边界以 Notion 中 2026-07-05 更新的项目总览、系统架构、Runtime Management、策略管理、本地调试和通知文档为准。代码库中的 dated audit、OpenSpec archive、Superpowers plans/specs 属于历史证据，不因术语过时而删除。

本次采用“保守清理”方案：只删除有可复查静态证据、不会改变当前产品入口和协议契约的内容；仍可能被仓库外客户端、兼容数据或内部调试路径使用的接口暂缓删除。

## 目标

1. 删除生产不可达、编译不参与、零引用且已有替代的代码和脚本。
2. 删除已经被当前 Portfolio 流程完整替代、继续保留只会误导操作人员的当前态文档。
3. 更新仍承担入口、部署或开发指导职责的文档，统一到 Portfolio/Venue、RuntimeChannel、Go runtime-agent 和 Python session worker 架构。
4. 保证登录、Portfolio、Venue、Strategy、Market Data、Runtime、Session、Order、Reconciliation、Notification、Observability 和本地调试功能不发生行为变化。
5. 每个删除项都保留“为什么可删、替代入口在哪里、用什么验证”的证据。

## 非目标

1. 不重构业务架构，不修复与清理无关的产品缺陷。
2. 不删除或修改数据库 migration 历史。
3. 不删除 Notion 明确保留的 hosted/self-hosted executor、bare runtime、内部 debugger gate、debug package 或本地 `strategy-debugger-cli`。
4. 不删除公开 Python library 导出，仅凭仓库内零引用不足以证明外部用户未使用。
5. 不删除 proto/RPC 契约。本轮暂缓 `GetPortfolioMeta`、`GetVenueRouteMeta`、`ValidateStrategyCode` 和 `GetLiveConsumptionDiagnostics`，它们需要独立的契约下线设计。
6. 不删除 legacy DB read fallback、历史 session/status 兼容或旧 runtime payload 的 fail-closed 错误分支。
7. 不清理 `.venv`、`node_modules`、`__pycache__`、pytest cache 等本机忽略产物；它们不是源码变更。
8. 不删除带有现有未提交修改、但无法确认修改来源的候选文件，例如当前被修改的 `ChartsPlaceholder.tsx`。

## 功能保护清单

以下能力必须在清理前后保持相同入口和行为：

1. Auth：注册、登录、JWT 和受保护页面。
2. Portfolio/Venue：创建、查询、绑定、释放、归档、凭据和钱包快照。
3. Strategy：创建、挂载、激活、运行与策略声明校验。
4. Runtime：hosted/self-hosted executor、RuntimeChannel credential、心跳、恢复、bare debug。
5. Local debugging：debug package、`strategy-debugger-cli` import/replay、VS Code 调试、bare runtime 内部定位流程。
6. Market Data：history coverage、paged backtest、live stream、Kafka delivery 和 scraper writer lease。
7. Session：preview、run、status、stop、stop-and-close、recoverable/resume 和详情页。
8. Order：intent/attempt/order/fill、partial fill、recovery scanner、WebSocket callback 和 REST fallback。
9. Wallet/Reconciliation：portfolio/venue snapshot、runtime wallet、checkpoint/event/sample/end 对账。
10. Notification/Observability：用户通知偏好、Telegram、custom notify、Kafka 日志、Jaeger trace。

## 删除范围

### 1. quant-handler 不可达旧 Runtime 路由

删除：

- `gateway/quant-handler/internal/app/runtime_route.go`
- `runtime_route_test.go` 中仅直接调用该 handler 的两个测试
- `gateway/quant-handler/README.md` 中声称旧 endpoint 返回 `410 Gone` 的说明

证据：handler 未注册到 `app.go` 的 HTTP mux，生产 HTTP 请求当前得到的是普通 404；唯一调用者是两个单元测试。`runtime_route_test.go` 中被其他测试复用的 fake/helper 必须保留。

当前替代入口：Runtime 列表与详情使用 `runtime_id`，实际路由由 control-panel `ResolveRuntimeRouteByID` 完成。

### 2. scraper 旧 Elemental 源码副本

删除：

- `scraper/internal/logger/vendor/**`
- `scraper/Dockerfile` 中复制或描述该 vendor/Elemental 源码的旧注释

证据：scraper 的实际 logger wrapper 只 import `github.com/hushine-tech/golang-lib/pkg/log`；`go list -deps ./...` 不包含该 vendor 路径；`internal/logger` 的实际编译文件只有 `helpers.go`、`logger.go`。

必须保留 `scraper/internal/logger/logger.go`、`helpers.go` 和测试，它们是当前 collector、storage、Kafka publisher 与 control-plane client 的日志入口。

### 3. strategy-service 零引用遗留文件

在再次执行全工作区引用检查后删除：

- `strategy-service/requirements.txt`：当前依赖真相源为 `pyproject.toml + uv`。
- `strategy-service/generate_order_proto.sh`：功能已被 `generate_proto.sh` 覆盖。
- `strategy-service/verify_algo_flow.py`：零调用，引用不存在的 OpenSpec change，并假设旧固定行情数据库。
- 空的 `strategy-service/strategy_service/cli/__init__.py`。
- 空文件 `strategy-service/tests/hello`。

不得删除 `strategy_service/grpc_server.py`。当前 Python session worker 仍直接实例化其中的 `StrategyServiceServicer`，它虽然保留旧文件名，实际承担当前 Run/Status/Stop 核心执行逻辑。

不得删除 `debug_strategy_sources.py`。当前 Run/Preview 和 bare runtime 本地策略物化流程仍使用它。

### 4. 已被替代的当前态文档和失效审计入口

删除：

- `hushine-deploy/docs/chrome-devtools-smoke-test.md`，并删除 README 与 production checklist 中指向它的链接。该文档仍以 Account API、旧 mode 和 Python `:50053` 服务为主，当前 Portfolio 用户手册与 coverage audit checklist 已完整替代它。
- 根 `progress/roadmap.md`。该文件自称当前 onboarding map，但仍以 6 月的 Account/Phase 3 架构为当前事实；当前状态由 Notion 和新的 feature-data-flow 文档维护。
- 根 `scripts/audit/run_audit.sh` 及根 Makefile 的 `audit` target。脚本引用多个已经不存在的测试文件，当前 `make test` 与 code-census 是替代入口。

保留：

- `progress/discuss.md`，它明确是项目演进历史。
- `docs/audit/*2026-*`、OpenSpec archive、Superpowers plans/specs。

## 文档更新范围

以下文件仍有当前入口价值，不整篇删除：

1. 根 `AGENTS.md` 与 `hushine-deploy/AGENTS.md`：删除过时的 Stage/C3 快照，改为当前 Portfolio/Venue、RuntimeChannel、Go runtime-agent/Python worker、离线 CLI 和已落地 order recovery 的简明说明。
2. `hushine-deploy/README.md`：改为 `portfolio.v1`、RuntimeChannel/Go agent，单独说明 scraper 仍使用 `log-config.json`。
3. `gateway/quant-frontend/README.md`：从 trading account/未来 TradingView 改为当前 Portfolio/Venue/Runtime/Session/Order/Notification UI 和现有 session chart。
4. `scraper/README.md`：区分支持能力与默认启用配置；修正 funding REST、控制面当前托管范围、日志默认值和不存在的 compose 命令。
5. `strategy-library/README.md`：补齐公开 `hushine_strategy` SDK、validator、replay、wallet 能力，删除“真实订单服务待开发”的旧结论。
6. `golang-lib/README.md`：使用实际存在的 HTTP/gRPC API 和当前 Go 版本。
7. `docs/user-runbook.md`、`docs/runtime-operator-flow.md`、`docs/local-docker.md`、coverage audit 配置和 deploy checklist：将已删除的 `hushine-runtime` 命令替换为 runtime-agent 或 bare debugpy 启动方式，将 self-hosted 地址修正为 RuntimeChannel `:50055`。
8. `core-service/config.yaml`：只更新已过时注释，不改变配置值。

根目录与 `hushine-deploy` 存在同名分叉脚本。本轮不直接删除任一套；`hushine-deploy` 是版本化部署真相源，根目录入口继续作为工作区 wrapper。仍被根 wrapper 调用的旧 E2E/debugger 脚本必须更新，而不能直接删除。

## 执行顺序

1. 保存所有子仓库的 `git status --short` 基线，标记本次允许修改的文件。
2. 逐项做删除前引用检查，若发现新的生产、启动、Docker、CI 或文档入口，立即取消该删除项。
3. 先处理单仓库高置信删除：quant-handler、scraper、strategy-service。
4. 再处理已替代文档和失效 audit target。
5. 更新当前态文档与脚本引用；对现有 dirty 文件只做最小局部补丁。
6. 每完成一个仓库就运行对应测试，不把所有问题积累到最后。
7. 最后运行全工作区验证、过时词汇扫描和 Git diff 审核。

## 错误处理与停止条件

出现以下任一情况时停止对应删除，不扩大假设：

1. 删除候选出现新的生产注册、动态 import、Docker/CI 或仓库外明确契约证据。
2. 需要覆盖用户未提交修改才能完成删除。
3. 生成代码变化超出本次预期，或要求同时下线 proto/RPC。
4. 对应仓库测试在删除后出现新失败，且恢复候选文件可消除失败。
5. Notion 功能保护清单中的入口、状态或数据流发生变化。

本次使用小批量补丁，不执行 `git reset --hard`、`git checkout --` 或其他覆盖用户工作的方法。

## 验证策略

### 删除项定向验证

- quant-handler：确认旧 handler 零引用；运行 `go test ./internal/app` 和 `go test ./...`。
- scraper：运行 `go list -deps ./...`、`go test ./...`、`go vet ./...`，确认 Elemental vendor 不再出现。
- strategy-service：全工作区引用扫描；运行 Python 全量 pytest 与 Go runtime-agent tests。
- 文档/脚本：执行链接与关键词扫描，确认当前态文档不再把 `account.v1`、`:50053`、`uv run hushine-runtime` 或旧 `/api/accounts` 当作当前入口。

### 全量回归

按仓库运行：

```text
core-service                 go test ./...
control-panel-service       go test ./...
gateway/quant-handler       go test ./...
scraper                     go test ./...
golang-lib                  go test ./...
strategy-service            Python pytest + Go runtime-agent tests
strategy-library            pytest
strategy-debugger-cli       pytest
gateway/quant-frontend      npm run build + repository tests
OpenSpec                    strict validation
```

若环境允许，再运行根工作区脚本 smoke。已存在的基线失败必须和清理后结果逐项对比；不能把旧失败写成新回归，也不能声称全量通过。

## 验收标准

1. 所有计划删除项都有零生产引用或明确替代入口证据。
2. Notion 功能保护清单中的所有能力仍有当前代码入口。
3. 本轮没有删除 proto/RPC、migration、公共 library API 或内部 debugger 兼容边界。
4. 所有本轮涉及仓库的测试和构建没有新增失败。
5. 当前态文档不再指导用户使用已删除命令、旧 Account API 或旧 Python `:50053` 产品路径。
6. 明确历史文档仍保留，且不会被误当作当前操作手册。
7. Git diff 只包含设计批准范围内的删除和最小文档修正，不夹带用户原有修改。

## 后续独立清理候选

以下内容有较强未使用证据，但因涉及契约或兼容边界，不进入本次保守清理：

1. `PortfolioService.GetPortfolioMeta` 与 `GetVenueRouteMeta` RPC transport surface。
2. direct `StrategyService.ValidateStrategyCode` 与 `GetLiveConsumptionDiagnostics` RPC。
3. `BacktestDataLoop` / `LiveDataLoop` 兼容导出与旧 session hook。
4. control-panel `StartDebugReplay` 兼容链路。

这些候选应分别确认外部客户端、Notion 产品语义、生成代码同步和替代入口后，再设计独立的契约下线变更。
