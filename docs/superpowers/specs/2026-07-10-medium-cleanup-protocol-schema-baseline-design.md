# Hushine 中等级清理、协议收口与数据库 Baseline 设计

日期：2026-07-10

状态：设计已在对话中批准；文档提交后等待实施前最终复核

## 1. 背景与目标

Hushine 已完成一轮保守清理。本轮提高到中等级，目标是删除已经被当前
Portfolio/Venue、RuntimeChannel 与平台代理路径替代的实现，同时把允许整体清库重建的
四套数据库迁移历史收口为当前 Schema Baseline。

本轮不是产品功能裁剪。删除前已经按 Notion 当前产品语义和工作区代码完成四批功能确认：

1. 身份、导航、Portfolio、Venue、Strategy 全部保留。
2. Market Data、Runtime、Session、Order 全部保留。
3. Wallet、Reconciliation、Debugger、Telegram Notification、Observability、Deployment 全部保留。
4. 仅删除已经逐项批准的旧实现、零生产调用 RPC transport、历史迁移链与失效工具入口。

数据库兼容边界已经确认：所有环境可统一清空并重建，不要求旧数据库原地升级；所有服务、
Runtime、凭证和受控客户端可协调切换。

## 2. 当前事实源与架构边界

当前产品行为以 Notion 项目总览、系统架构、Runtime Management、Market Data、Notification、
用户手册和 Strategy 编写详解为准。Notion 中仍存在 `account.v1`、旧 Python `:50053` 等历史
实现名称时，只采纳其产品语义，不把旧实现名称当作当前代码契约。

本轮必须保持以下架构：

- quant-frontend 只通过 HTTP/JWT 访问 quant-handler。
- quant-handler 通过 `portfolio.v1` 与 `order.v1` 访问 core-service。
- quant-handler 通过 control-panel-service 访问 Runtime、Market Data 与 Strategy proxy。
- 所有 Runtime Session 只按 `runtime_id` 路由。
- hosted/self-hosted/bare runtime-agent 通过 RuntimeChannel 连接 control-panel-service。
- Go runtime-agent 启动隔离的 Python session worker，并通过 `runtimeworkerv1.Connect` 通信。
- Runtime 通过 platform proxy 访问 Portfolio、Order 与 Market Data，不获得内部 DB、Kafka、
  account 或 order 地址。
- `environment=2` 继续受 rollout guard 保护；OKX 和不支持模式继续 fail closed。

## 3. 已批准的功能保护矩阵

以下能力均为硬保护项。任何候选删除若影响其中一项，立即停止对应删除：

| 域 | 保留能力摘要 |
|---|---|
| Identity / UI | 注册、登录、JWT、用户资料、导航、Quick Start、路由保护 |
| Portfolio / Venue | CRUD、绑定、凭证、状态、Backtest/Demo/Live、钱包汇总、快照 |
| Strategy | CRUD、挂载、激活、`INPUTS`、`ORDER_TARGETS`、`INDICATORS`、回调、校验、Preflight |
| Market Data | 实时/历史请求、覆盖率、Viewer、Scraper、年库、Kline/Orderbook/Funding/OI、租约、Kafka、分页回测 |
| Runtime | Hosted/Self-hosted、凭证、RuntimeChannel、认证、心跳、恢复、命令、资源配置、Admission diagnostics |
| Session | Preview、Run、Status、Stop、Stop-and-close、持久化、恢复、详情、指标、风险限制 |
| Order | Intent/Attempt/Order/Fill、生命周期、部分成交恢复、更新回传、Venue 路由、错误透明 |
| Wallet / Reconciliation | Spot/Futures、保证金、持仓、挂单占用、资金流水、快照、Hard/Soft/Advisory 对账 |
| Debugger | Offline CLI、Replay、Validate/Repair、VS Code、Debug Package、Bare Debugger、热加载 |
| Notification | Telegram 绑定/解绑/测试、偏好、Plan、限流、交付状态、`self.notify()`、异步 Kafka |
| Operations | 日志、ELK、Tracing、Metrics、Health、测试、部署、证书、过期资源清理、数据库初始化 |

## 4. 已批准的删除与迁移决策

### D01：删除旧 TimescaleDB/Kafka 直连数据循环

删除 `BacktestDataLoop`、`LiveDataLoop`、包级兼容导出、`SessionState.live_loop`、
`set_live_loop()`、旧 stop hook 以及只服务这两个类的测试。

`_adapt_kline()` 仍被当前分页回测与 RuntimeChannel 实时执行使用，必须迁移到独立的当前态行情
适配模块后再删除 `data_loop.py`。

保留：

- `PagedBacktestDataSource` 分页回测。
- RuntimeChannel live event/K-line 交付。
- order update 优先处理、indicator collection、Session stop 与状态持久化。
- 当前 unroutable/backpressure 诊断。

### D02：删除 Python 旧 Runtime 配置加载器

删除 `strategy_service/config.py`、`tests/test_config_env.py` 和仅由该实现需要的直接 PyYAML 项目
依赖。当前 Runtime 配置真相源为 Go `internal/runtimeagent/config.go`。

`scripts/smoke_strategy_runtime.sh` 改为验证：

- Go runtime-agent 能读取当前 `config.yaml` 并正常启动帮助入口。
- Python session worker 与 RuntimeChannel/worker proto 可导入。
- 不再把 Python Config loader 当作镜像健康条件。

### D03：删除 Python 直连 Market Data gRPC Client

删除 `strategy_service/marketdata_client.py`。当前生产路径只使用 `ProxyMarketDataClient`，经
RuntimeChannel/platform proxy 访问 control-panel-service。

生成的 Market Data message 类型按当前 proto 生成流程保留；不得因为删除直连 client 而删除
platform proxy 需要的消息类型。

### D04：删除两个零生产调用 RPC transport

删除：

- `PortfolioService.GetPortfolioMeta`
- `PortfolioService.GetVenueRouteMeta`

删除范围包括 proto RPC、专用 Request/Response message、服务端 transport 实现、生成代码和
仅测试该 transport 的测试片段。

零调用结论限定为“当前工作区受控生产客户端中没有 RPC 调用点”：

- 全工作区搜索普通调用、Request/Response 类型、完整 gRPC method string 和动态字符串调用。
- 排除 proto、生成代码和测试后，只剩两个服务端方法定义。
- quant-handler、control-panel-service、strategy-service 与 scraper 中没有调用。
- `GetPortfolioMeta` 的引用仅为 proto、生成 stub、服务端和服务端测试。
- `GetVenueRouteMeta` 的引用仅为 proto、生成 stub、服务端和服务端测试。

本地历史 access log 存在一条 2026-05-30 的旧
`/account.v1.AccountService/GetVenueRouteMeta` 调用。它证明 Account-era 路径曾被使用，但不是当前
`portfolio.v1` transport；当前源码和日志均未发现 `portfolio.v1` 调用。

必须保留 core-service 内部的 `ResolveVenueRouteMeta` repository 能力。Order module 当前通过
in-process repository adapter 获取 Venue 路由，Preflight 与钱包路径也直接使用该内部能力。

这两个旧 transport 可返回解密凭证；删除零调用远程暴露面同时减少凭证泄露面。不得删除当前
Venue credential manager、Order routing 或 Preflight 依赖。

### D05：删除独立 Live Consumption Diagnostics RPC

删除 `StrategyService.GetLiveConsumptionDiagnostics` 及其专用 wire messages。当前受控客户端没有
调用，quant-handler 的 control-panel adapter 明确返回 `Unimplemented`。

保留内部 live consumption、unroutable 与 backpressure 状态；用户/运维诊断继续通过
`MarketDataControlPlaneService.ListSessionDeliveryHealth`、RuntimeChannel metrics、Session 状态和
日志提供。

### D06：迁移校验后删除独立 ValidateStrategyCode RPC

当前 `StrategyService.ValidateStrategyCode` 没有受控客户端调用，control-panel adapter 明确返回
`Unimplemented`。但策略校验是已确认保留功能，因此不能直接连同 validator 删除。

顺序固定为：

1. 把 `strategy_validator.validate_strategy_code` 纳入当前 Preview/Run 共用 Preflight 路径。
2. 增加无效语法、禁用 debugger module、合法策略和 Preview/Run parity 测试。
3. 确认 UI/Handler 仍从 Preview/Run 得到结构化校验失败。
4. 再删除独立 RPC、消息、servicer method 与 quant-handler 的无实现 interface shim。

### D07：历史迁移链收口为当前 Schema Baseline

四个数据库域均保留运行时 migrator 和 `schema_migrations`，但删除现有历史增量、rename、drop、
hard-cut 和先建后删链路，替换为当前结构 Baseline。

建议每个域保留：

- `0000_create_schema_migrations.sql`
- `0001_current_schema_baseline.sql`

之后的新功能从 `0002_*.sql` 起追加。Baseline 面向 fresh DB；旧 migration history 不再支持原地
升级。部署文档必须明确要求清空并重建旧环境。

#### Portfolio Baseline

必须包含：

- `users`
- `portfolios`
- `venues`
- `venue_wallet_states`
- `venue_events`
- `session_venues`
- `portfolio_snapshots`
- `current_portfolio_snapshots` view
- `strategies`
- `portfolio_strategies`
- `strategy_sessions`
- `strategy_indicator_definitions`
- `strategy_indicator_chunks`
- `reconciliation_runs`
- `notification_settings`
- `notification_channels`
- `notification_plans`

同时保留所有当前 status/environment CHECK、active Session guard、唯一约束、外键边界、Timescale
hypertable、索引和通知默认 Plan 数据。

#### Order Baseline

必须包含：

- `order_intents`
- `order_attempts`
- `orders`
- `order_fills`
- `order_lifecycle_events`

保留 Venue route facts、limit/post-only/good-till-date/reduce-only、risk audit、recovery scan、event
source、event identity、幂等与 Timescale 约束。

#### Control Panel Baseline

必须包含：

- `runtime_registry`
- `runtime_credentials`
- `runtime_commands`
- `runtime_channel_leases`
- `runtime_admission_failures`
- `runtime_debug_datasets`
- `market_data_streams`
- `market_data_requests`
- `market_data_history_requests`
- `market_data_leases`
- `session_market_data_subscriptions`
- `stream_delivery_leases`
- `stream_delivery_failures`
- `market_data_writer_leases`
- `market_data_coverage_segments`

保留 hosted/self_hosted/bare、executor/debugger、credential lifecycle、mTLS、resume、cleanup、debug
workspace/dataset、delivery progress、environment 与 writer lease 约束。

#### Market Data Year Baseline

必须包含：

- TimescaleDB extension
- `spot_klines`
- `futures_klines`
- `spot_orderbook`
- `futures_orderbook`
- `futures_funding_rates`
- `futures_open_interest`

保留 hypertable、symbol/year 路由、唯一索引、时间索引、压缩/存储策略中当前仍生效的部分。

### D08：重新生成当前 DDL bundles

`db/generated/portfolio.sql`、`order.sql`、`control_panel.sql`、`market_data_year.sql` 必须从新
Baseline 重新渲染，不再串行执行历史 hard-cut。

`00_create_databases.psql` 继续幂等创建 `portfolio`、`order`、`control_panel` 和当前交易所年库。
手工 bundle 与 `make ensure-dbs` 使用同一 Schema 真相源。

### D09：删除失效 Audit 入口

删除 `hushine-deploy/scripts/audit/run_audit.sh` 与对应 `make audit` target。该脚本引用六个不存在的
strategy-library 测试文件，已经不是可信验证入口。

保留并使用：

- 各仓库 `make test` / 原生测试命令。
- Code Census。
- RuntimeChannel hosted/self-hosted smoke。
- Debugger smoke。
- Full-flow E2E。

### D10：清理旧协议注释与生成物

删除把 StrategyService 描述为 `BacktestDataLoop (TimescaleDB)` / `LiveDataLoop (Kafka)` 的 proto
注释，改为分页 Platform Market Data 和 RuntimeChannel live delivery。使用仓库生成脚本重新生成
Go/Python 代码，禁止手改生成文件。

## 5. 明确保留的技术项

以下项目不进入本轮删除：

- `PrepareDebugWorkspace`、`LoadDebugDataset`、`GetRuntimeDebugDataset`。
- generic platform proxy 中的 `StartDebugReplay` 请求/响应与 debugger service 链路。
- Bare Debugger、热加载、IP allowlist 与 debug capability gate。
- `RuntimeChannel`、Runtime Worker `Connect`、Go agent 和 Python worker。
- `PortfolioClient`、`OrderClient` 中仍被 Proxy 或 Strategy Engine 复用的类型和转换逻辑。
- 其余 Portfolio、Order、Control Panel、Market Data、Strategy RPC。
- OpenSpec archive、日期化 Superpowers specs/plans 和明确标记为历史的材料。
- 根目录非 Git 工作区 wrapper 与 `hushine-deploy` 中仍有效的版本化部署入口。

## 6. 数据库一次部署与幂等验收

不得使用共享 `192.168.88.10` 做破坏性验证。验证使用隔离的临时 PostgreSQL/TimescaleDB 实例，
或显式唯一的临时数据库名，并在执行前输出目标 host/database 供复核。

固定验收顺序：

1. 从空实例创建 portfolio/order/control_panel/market-data year DB。
2. 运行第一次 `make ensure-dbs`。
3. 对照 repository SQL 和 DB README 检查所有表、view、extension、hypertable、index、constraint、
   trigger 与 seed row。
4. 启动 core-service、control-panel-service、scraper、quant-handler 与必要 Runtime 组件。
5. 执行关键 API/Smoke/E2E，至少覆盖登录、Portfolio/Venue、Strategy Preview/Run、分页回测、
   RuntimeChannel、Order、Session detail、Telegram settings schema 和 Market Data coverage。
6. 在同一实例第二次运行 `make ensure-dbs`。
7. 比较两次 schema、migration rows 与服务行为，确认无报错、无重复对象、无数据破坏。
8. 如条件允许，直接重复执行生成 SQL bundle，验证手工路径同样幂等。

只有“DDL 成功”不足以验收；必须证明服务 repository 能正常读写，避免缺字段、错误默认值或遗漏
索引导致服务启动后失败。

## 7. 执行顺序

1. 保存所有独立仓库 `git status --short` 和 branch/upstream 基线。
2. 先实现 D06 校验迁移并测试，避免先删 wire surface 后丢失保留功能。
3. 执行 strategy-service D01/D02/D03/D10 清理并运行 Python/Go 全量测试。
4. 执行 D04/D05/D06 proto 收口，重新生成所有受影响仓库代码并运行 consumer 测试。
5. 从最终 schema 设计并验证四套 Baseline，再删除旧 migrations。
6. 重新渲染 DDL bundle，执行隔离 fresh deploy、服务 smoke 和第二次幂等验证。
7. 删除 D09 失效 audit 入口，更新当前部署/DB 文档。
8. 运行全工作区测试、OpenSpec strict validation、引用扫描和 Git diff 审核。
9. 每个独立仓库只暂存本轮文件，分别提交并推送当前远程分支。

## 8. 验证矩阵

至少运行：

```text
core-service                 go test ./... && go vet ./...
control-panel-service       go test ./... && go vet ./...
gateway/quant-handler       go test ./... && go vet ./...
scraper                     go test ./... && go vet ./...
golang-lib                  go test ./... && go vet ./...
strategy-service            Python pytest + Go tests + tracked shell tests
strategy-library            managed-environment pytest
strategy-debugger-cli       managed-environment pytest
gateway/quant-frontend      npm run build + scripts/*.test.mjs
OpenSpec                    openspec validate --all --strict --no-interactive
Database                    isolated fresh deploy + service smoke + second-run idempotency
```

删除 RPC 后增加全工作区负向扫描，确认 D04/D05/D06 symbol 不再出现在非历史资料、非生成缓存或当前
生产代码中。D04 的内部 `ResolveVenueRouteMeta` 必须继续存在并由 Order/Preflight 测试覆盖。

## 9. 错误处理与停止条件

出现以下任一情况，停止对应删除并保留候选：

1. 发现新的生产注册、动态调用、外部客户端清单或运行日志证据。
2. 删除影响任一已批准保留功能。
3. 生成代码变化超出 proto 变更预期。
4. Baseline 无法从空库一次完成部署。
5. 第二次初始化不幂等。
6. Repository 或服务 smoke 暴露缺字段、约束、索引、view、extension 或 seed 数据。
7. 删除后出现基线中不存在的测试失败。
8. 工作区出现与本轮文件重叠的用户未提交修改。

不得执行 `git reset --hard`、`git checkout --` 或自动清空共享数据库。任何目标 host/database 不明确
时，数据库破坏性步骤直接停止。

## 10. 提交、推送与最终报告

工作区根不是 Git；每个服务独立提交。每个仓库在测试通过后形成目的单一的 commit，最终统一
push 当前分支。只暂存本轮拥有的文件和 hunk。

最终报告必须列出：

- 删除、迁移和修改的文件。
- 每个仓库的 commit SHA、branch、remote push 状态。
- `git diff --numstat` 与删除文件 `wc -l` 统计。
- 删除行、新增行和净减少行，区分生成代码、migration 与手写代码。
- 删除的 RPC、message、class、hook、migration 和脚本。
- 所有测试、构建、OpenSpec、fresh DB、服务 smoke 与幂等结果。
- 任何未执行或因环境受限跳过的验证，不得把跳过描述成通过。

## 11. 验收标准

1. D01-D10 全部按批准边界完成，没有新增产品功能删除。
2. 所有功能保护矩阵能力仍有生产代码入口和测试证据。
3. Runtime 不直接连接内部 DB、Kafka、Portfolio 或 Order 地址。
4. D04 只删除 RPC transport，内部 Venue route resolution 继续工作。
5. 策略校验在 Preview/Run Preflight 中生效后才删除独立 RPC。
6. 四套数据库可从空实例一次部署并正常启动服务，第二次执行幂等。
7. 当前文档与 proto 不再把旧数据 Loop 或 Account-era 路径描述为当前实现。
8. 全量验证没有新增失败。
9. 所有本轮改动已提交并推送，最终文件和行数统计可复核。
