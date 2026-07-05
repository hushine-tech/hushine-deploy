# Hushine 数据库清单

一个**唯一入口**的部署 DB 文档。所有数据库、每张表的归属、迁移文件路径都在这里登记,部署新环境时按本文件走就不会漏表。

> 每个服务仍然在自己的 repo 里维护 `internal/storage/migrations/*.sql`作为 schema 真相源 —— 不做物理集中以避免跨 repo 依赖。
> 本文件是 **部署清单 + 反向索引**。

## 一键部署

从仓库根目录运行:

```bash
make ensure-dbs
```

它会按依赖顺序调用每个服务的 `ensure-db` 子命令,幂等(表已存在会跳过)。

等价手动步骤:

```bash
cd core-service       && make ensure-db         # 创建 portfolio
cd core-service       && make ensure-order-db   # 创建 order
cd control-panel-service && make ensure-db   # 创建 control_panel (Phase D1)
cd scraper               && make ensure-db   # 创建 {exchange}_{year} 行情库
```

## 建表 SQL bundle

如果后续要在其他机器部署前先审阅完整建表语句，或需要走手工 `psql` bootstrap，可以从当前 migration 渲染一份 SQL bundle：

```bash
make db-schema-bundle
```

生成文件在 [db/generated/](generated/)：

| 文件 | 连接目标 | 内容 |
|---|---|---|
| `00_create_databases.psql` | `postgres` 管理库 | 幂等创建 `portfolio` / `order` / `control_panel` / 当前年份 `binance_YYYY` / `okx_YYYY` 数据库；使用 `psql \gexec` |
| `portfolio.sql` | `portfolio` | core-service portfolio DB 的全部 migration DDL |
| `order.sql` | `order` | core-service order module 的全部 migration DDL |
| `control_panel.sql` | `control_panel` | control-panel-service 的全部 migration DDL |
| `market_data_year.sql` | 每个 `{exchange}_{year}` 行情库 | scraper 年库通用 DDL；对 `binance_2026` / `okx_2026` 这类库分别执行一次 |

手工执行顺序示例：

```bash
psql -h <host> -U <admin_user> -d postgres -v ON_ERROR_STOP=1 \
  -f db/generated/00_create_databases.psql
psql -h <host> -U <admin_user> -d portfolio -v ON_ERROR_STOP=1 \
  -f db/generated/portfolio.sql
psql -h <host> -U <admin_user> -d order -v ON_ERROR_STOP=1 \
  -f db/generated/order.sql
psql -h <host> -U <admin_user> -d control_panel -v ON_ERROR_STOP=1 \
  -f db/generated/control_panel.sql
psql -h <host> -U <admin_user> -d binance_2026 -v ON_ERROR_STOP=1 \
  -f db/generated/market_data_year.sql
psql -h <host> -U <admin_user> -d okx_2026 -v ON_ERROR_STOP=1 \
  -f db/generated/market_data_year.sql
```

注意：这些 bundle 会在每段 migration 后写入 `schema_migrations`，所以手工执行后仍然可以再跑 `make ensure-dbs` 做兜底检查。它们只适合 fresh DB 或审阅；历史 hard-cut migration 中存在 `DROP TABLE`，不要对带业务数据的半迁移库直接执行整包。

PG 连接信息通过标准环境变量:

| 变量 | 默认 | 说明 |
|---|---|---|
| `PGHOST` | `192.168.88.10` | PostgreSQL / TimescaleDB 主机 |
| `PGPORT` | `5432` | 端口 |
| `PGUSER` | `postgres` | 管理员用户名 |
| `PGPASSWORD` | `postgres` | 密码 |
| `PGDATABASE_ADMIN` | `postgres` | 用来执行 `CREATE DATABASE` 的默认 DB |

## 数据库清单

| 数据库 | 归属服务 | 作用 | 迁移路径 |
|---|---|---|---|
| `portfolio` | `core-service` | 用户/portfolio/策略/会话/对账（Phase D2 后不再持有市场数据控制面） | [core-service/internal/storage/migrations/](../core-service/internal/storage/migrations/) |
| `order`   | `core-service/order module`   | 订单四层执行域 (intent / attempt / order / fill) | [core-service/internal/order/storage/migrations/](../core-service/internal/order/storage/migrations/) |
| `control_panel` | `control-panel-service` | Phase D1 runtime 控制面 + Phase D2 市场数据控制面 + Phase D3 RuntimeChannel 凭证/路由/数据投递；回测分页读取也从这里做代理 | [control-panel-service/internal/storage/migrations/](../control-panel-service/internal/storage/migrations/) |
| `{exchange}_{year}` | `scraper` | 行情数据年库族，例如 `binance_2026` / `okx_2026`；K 线 / orderbook / funding / OI 都按事件时间路由到对应年份库 | [scraper/internal/storage/migrations/](../scraper/internal/storage/migrations/) |

> `strategy-service` / `strategy-runtime` 不持有自己的表。当前 RuntimeChannel 生产路径下，runtime 通过 platform proxy 调 core-service 写 `portfolio` / `order`，通过 control-panel-service 读取 market data；不再把回测数据集整包推给 runtime，也不再让 RuntimeChannel runtime 直接读行情库。

## 当前代码读写摘要

- **回测行情读取**：`strategy-service` 调 `marketdata.FetchBacktestPage`，由 `control-panel-service` 从 `{exchange}_{year}` 行情库按页读取，固定 page size 为 `8192`。分页游标使用最后一根 K 线的 `open_time`，下一页从 `open_time + interval` 开始；runtime 只流式消费，不保存 dataset 表。
- **demo/live 行情投递**：`control_panel.session_market_data_subscriptions` 记录 session 订阅，`stream_delivery_leases` 记录投递 worker 租约和 offset 进度；runtime 本地用双队列串行消费，`order_update` 会在下一根 K 线前优先处理。
- **demo/live 慢消费处理**：market data 按滞后时间丢弃，不按数量无限堆积。发生丢弃时 runtime 通过 RuntimeChannel 上报 `DATA_BACKPRESSURE`，control-panel-service 发通知；同一 `(session_id, stream_key)` 丢弃达到阈值后 runtime 发送 status patch，把 session 标记为 `failed`。
- **session 状态权威来源**：session 创建后，`portfolio.strategy_sessions` 是 UI 查询的持久化权威。backtest 详情直接读 DB；demo/live 在 runtime 查询超时或不可用时，quant-handler 会返回 DB 中的持久状态并附带 `status_stale/status_refresh_error`。
- **策略自定义指标**：用户策略通过 `MyStrategy.INDICATORS` 声明图表指标，runtime 在每根 K 线后把当前 bar 的指标值按 1024 bar chunk 写入 `portfolio.strategy_indicator_*` 表；Session Chart 按 `session_id + stream_key` 读取定义和 chunk，不重新计算用户指标。
- **recoverable 语义**：策略主体已经跑完，但 `strategy_end` snapshot、回测 wallet restore、或 stop 回写失败时，不再把 session 伪装成 `finished/running`，而是写成 `recoverable`，允许用户查看历史并显式 resume / 新开 session。

## 表清单 (按数据库分组)

### `portfolio` (core-service)

| 表 | 作用 | 首次引入 migration |
|---|---|---|
| `schema_migrations` | 服务运行时迁移记录表 | `0000_create_schema_migrations.sql` |
| `users` | 登录用户 + bcrypt 口令；`plan_code` 字段供 control-panel-service 读取（Phase D1）；`0036` 会为 hard-cut 后已存在业务行但缺失 profile 的历史 `user_id` 补最小 recovered 用户行 | `0005_add_user_ownership.sql`, `0011_add_user_plan_code.sql`, `0036_backfill_missing_user_rows.sql` |
| `portfolios` | portfolio / trading context；`environment=0/1/2` 表示 backtest/demo/live | `0019_portfolio_venue_hard_cut.sql` |
| `venues` | portfolio 下的 exchange / market / environment 交易场所；凭证、margin/position mode 挂在 venue 层 | `0019_portfolio_venue_hard_cut.sql` |
| `venue_wallet_states` | venue 级当前 wallet state；backtest venue 可游离持有 wallet，绑定后才进入 portfolio 汇总 | `0019_portfolio_venue_hard_cut.sql`, `0027_allow_unbound_venue_wallet_states.sql` |
| `venue_events` | venue bind / release / archive 审计事件 | `0019_portfolio_venue_hard_cut.sql` |
| `session_venues` | session 启动时捕获的 active venue 路由快照 | `0019_portfolio_venue_hard_cut.sql` |
| `current_portfolio_snapshots` | 当前 portfolio snapshot 只读视图；Phase 2 hard-cut 后统一从 portfolios 当前状态映射账号级 portfolio snapshot | `0021_portfolio_snapshot_hard_cut.sql` |
| `portfolio_snapshots` | 钱包快照 hypertable, 写入触发原因追溯；允许同一 portfolio/market time 下多 session 审计快照并按 session 查询 | `0002_create_portfolio_snapshots.sql`, `0028_portfolio_snapshots_allow_same_market_time.sql` |
| `strategies` | 策略定义 (name+version unique, immutable)；保存时记录 runtime_version/runtime_profile，供后续 runtime 版本兼容检查；归属由认证后的 JWT `user_id` 和 API 鉴权保证，不再要求本地 `users(id)` 外键 | `0003_create_strategies.sql`, runtime metadata 于 `0017_strategy_runtime_debug_metadata.sql`, `0035_drop_strategy_user_foreign_key.sql` |
| `strategy_sessions` | 策略运行 session (backtest/demo/live/debugging), Phase D 起持久化 owning runtime (`runtime_id` / source / runtime_name)；`error_code` / `error_message` / `error_detail_json` 保存 preflight 和结构化失败原因；`recoverable` 表示主体流程结束但最终状态/快照持久化异常，可恢复且不占用 portfolio active guard；`stop_failed` 表示 stop-and-close 或停止动作本身失败；`session_type` 区分 backtest/demo/debugging；`leverage` 保存启动策略时的会话级杠杆配置，供订单风控在空仓缺少 exchange risk metadata 时使用 | `0004_create_strategy_sessions.sql`, runtime binding 于 `0013` + `0015` rename, active guardrails 于 `0014` / `0030_strategy_session_active_index_excludes_recoverable.sql`, debug metadata 于 `0017_strategy_runtime_debug_metadata.sql`, structured preflight errors 于 `0023_strategy_session_preflight_errors.sql`, session leverage 于 `0031_strategy_session_leverage.sql`, stop failed status 于 `0032_strategy_session_stop_failed_status.sql` |
| `strategy_indicator_definitions` | session 图表自定义指标声明；按 `(session_id, stream_key, indicator_key)` 保存名称、类型 (`line/histogram/marker`)、pane、颜色、单位和 JSON 配置 | `0033_strategy_indicator_chunks.sql` |
| `strategy_indicator_chunks` | session 图表自定义指标数据 chunk；每条记录保存一个 indicator 的 1024 bar 左右的值或 marker JSON，按 `start_time_ms + offset * interval_ms` 对齐 K 线 | `0033_strategy_indicator_chunks.sql` |
| `portfolio_strategies` | portfolio-策略挂载/激活关系 | `0003_create_strategies.sql` |
| `reconciliation_runs` | Phase C 对账 diff 审计 hypertable | `0007_create_reconciliation_runs.sql`, pk 调整于 `0008` |
| `notification_settings` | 用户级通知总开关、分类偏好和最新发送诊断；不保存消息正文；归属由认证后的 JWT `user_id` 和 API 鉴权保证，不再要求本地 `users(id)` 外键 | `0016_create_notification_management.sql`, `0029_notification_settings_user_enabled.sql`, `0034_drop_notification_user_foreign_keys.sql` |
| `notification_channels` | 通用通知通道绑定表；当前只允许 `channel=telegram`，但字段使用 target_id/type/label 以承载后续 WhatsApp/Discord 等通道；归属同样不依赖本地 `users(id)` 外键 | `0016_create_notification_management.sql`, `0034_drop_notification_user_foreign_keys.sql` |
| `notification_plans` | core-service 拥有的通知 plan 配置；复用 `users.plan_code`，不读取 control-panel-service runtime plan | `0016_create_notification_management.sql` |

> Phase D2 (2026-05-06): 市场数据控制面（`market_data_streams` / `market_data_requests` / `market_data_leases` / `market_data_history_requests`）已迁出本库，搬到了下面 `control_panel` section；historical migrations `0009_create_market_data_control_plane.sql` 和 `0010_create_market_data_history_requests.sql` 在同次提交中被删除，新增的 `0012_drop_market_data_control_plane.sql` 仅做 `DROP TABLE IF EXISTS … CASCADE` 让旧库平滑退掉这 4 张表。

#### `strategy_sessions.status` 映射

DB 内部保存为 `SMALLINT`，gRPC/HTTP 对外统一返回字符串：

| DB code | API status | 语义 |
|---:|---|---|
| 1 | `pending` | session 已创建但尚未进入 preflight / running |
| 2 | `preflight` | 启动前检查中 |
| 3 | `running` | 正在执行；占用 portfolio active guard |
| 4 | `stopping` | 停止流程进行中；占用 portfolio active guard |
| 5 | `recoverable` | 运行主体或停止恢复已收束，但最终快照/状态回写异常；不占用 active guard |
| 6 | `finished` | 正常结束；legacy `completed` 会映射到这个状态 |
| 7 | `stopped` | 用户主动停止且已收束 |
| 8 | `failed` | 策略、preflight 后执行、runtime 或数据投递失败 |
| 9 | `preflight_failed` | 启动前检查失败；结构化原因写入 `error_code/message/detail_json` |
| 10 | `stop_failed` | stop / stop-and-close 动作失败，需要人工确认 |

### `order` (core-service order module)

| 表 | 作用 | 首次引入 migration |
|---|---|---|
| `schema_migrations` | 服务运行时迁移记录表 | `0000_create_schema_migrations.sql` |
| `order_intents` | 策略产生的交易意图；`post_only` / `good_till_date` / `reduce_only` 持久化平台订单语义 | `0006_order_venue_hard_cut.sql`, 订单语义字段于 `0010_order_risk_recovery_contract.sql` |
| `order_attempts` | 一次意图的执行尝试, 包含本地 attempt 状态、client order id、恢复错误；`post_only` / `good_till_date` / `reduce_only` 记录本次尝试语义，`risk_status` / `risk_reasons_json` 记录风控审计结果 | `0006_order_venue_hard_cut.sql`, 风控审计字段于 `0010_order_risk_recovery_contract.sql` |
| `orders` | 交易所接受后的订单, 与 attempt 一对一；`post_only` / `good_till_date` / `reduce_only` 记录落地订单语义，`recovery_status` / `recovery_started_at` / `next_check_at` / `recovery_deadline_at` / `last_recovery_error` / `force_closed_at` 支撑恢复扫描状态 | `0006_order_venue_hard_cut.sql`, 恢复状态字段于 `0010_order_risk_recovery_contract.sql` |
| `order_fills` | 订单成交明细 hypertable, 与 order/attempt/intent 关联 | `0006_order_venue_hard_cut.sql` |
| `order_lifecycle_events` | 订单生命周期事件流；`event_source` 标记 place_order/websocket/rest_recovery/force_close 来源，`event_identity` 为无 trade id 的状态事件提供幂等 upsert 键 | `0007_order_lifecycle_events.sql`, 路由字段于 `0009_order_lifecycle_route_facts.sql`, 来源和幂等字段于 `0012` / `0013` |

### `control_panel` (control-panel-service, Phase D1)

| 表 | 作用 | 首次引入 migration |
|---|---|---|
| `schema_migrations` | 服务运行时迁移记录表 | `0000_create_schema_migrations.sql` |
| `runtime_registry` | 平台已知的所有 strategy-runtime；`source=hosted/self_hosted/bare`，其中 `bare` 只用于 debug 部署的临时裸机接入；`role=executor/debugger`；status 状态机当前为 `paired/active/unhealthy/ended`；hosted 的 token_hash；self_hosted 行记录 credential_key_id 便于吊销；非 ended 行要求一个 credential_key_id 只能绑定一个 runtime；同一 user 的 `name` 全生命周期唯一；runtime 选择只以 `runtime_id` 为准，`name` 只是不可变展示名；connection owner 字段记录当前 RuntimeChannel owner instance；cleanup 字段记录 hosted deprovision 成败或 self-hosted 用户自管容器边界；debug workspace 字段记录 self-hosted debugger 的模板准备状态 | `0001_create_runtime_registry.sql`, `0008_add_runtime_registry_credential_key_id.sql`, `0010_unique_active_runtime_credential.sql`, `0011_allow_multiple_selected_runtimes_per_service.sql`, `0012_unique_active_hosted_runtime_slot.sql`, lifecycle rename 于 `0013_runtime_identity_lifecycle.sql`, role/owner 于 `0014_runtime_identity_role_owner.sql`, cleanup state 于 `0023_runtime_cleanup_state.sql`, debug workspace 于 `0026_runtime_debug_state.sql`, bare source 于 `0028_allow_bare_runtime_source.sql` |
| `market_data_streams` | 每条物理流的聚合状态 (desired/actual + live delivery) — **Phase D2 从 portfolio 库迁入** | `0003_create_market_data_streams.sql` |
| `market_data_requests` | 用户声明的 kline 流需求 (demand-driven control plane) — Phase D2 迁入 | `0004_create_market_data_requests.sql` |
| `market_data_leases` | 活跃 demo/live-data session 的 TTL 占用 — Phase D2 迁入 | `0005_create_market_data_leases.sql` |
| `market_data_history_requests` | 有限时间窗口历史数据请求/回填状态 — Phase D2 迁入 | `0006_create_market_data_history_requests.sql` |
| `runtime_credentials` | RuntimeChannel credential 元数据；保留旧 Ed25519 公钥/生命周期字段，并记录 mTLS client certificate PEM、fingerprint、expiry、issuer；私钥只返回一次，不入库；hosted-internal credential 不对用户展示 secret | `0007_create_runtime_credentials.sql`, lifecycle 字段于 `0015_runtime_credential_lifecycle.sql`, client certificate metadata 于 `0030_runtime_credential_client_cert.sql` |
| `runtime_commands` | runtime 异步命令记录；包含 target runtime、可选 session、幂等键、状态、deadline、ack/completion 时间、payload/result/failure reason | `0016_create_runtime_commands.sql` |
| `session_market_data_subscriptions` | session 从策略 input universe 派生出的授权数据订阅；绑定 session/runtime/market/symbol/interval/environment；demo/live 运行只接收这里授权过的 stream | `0017_create_runtime_data_delivery_leases.sql`, `mode` rename 为 `environment` 于 `0027_session_delivery_environment.sql` |
| `stream_delivery_leases` | Kafka/control-panel delivery worker 对 session subscription 的投递所有权租约；支持 heartbeat、expiry、steal/release，并记录最后一次投递的 topic/partition/offset/时间用于 delivery health；投递失败或 runtime backpressure 不在这里写大 payload，只写进度/诊断 | `0017_create_runtime_data_delivery_leases.sql`, progress columns 于 `0024_stream_delivery_progress.sql` |
| `stream_delivery_failures` | Kafka/control-panel delivery worker 的非敏感失败诊断；记录 subscription/topic/stream_key/failure_code/reason/attempt_count，供 runtime/session delivery blocked 状态排查；不保存 K 线正文 | `0022_create_stream_delivery_failures.sql` |
| `market_data_writer_leases` | scraper 写入 `(exchange, market, kind, symbol, interval, year)` 前必须持有的 writer lease；记录 owner/scraper/collector/lease 状态 | `0018_create_market_data_writer_leases.sql` |
| `market_data_coverage_segments` | 历史行情覆盖索引；按 `(exchange, market, kind, symbol, interval, year)` 保存连续可用区间，供 Market Data 时间轴、backtest preflight 和 download-and-run 判断缺口 | `0025_create_market_data_coverage_segments.sql` |
| `runtime_channel_leases` | RuntimeChannel 同进程续连 token 的 hash 租约；原始 token 只在 runtime 进程内存中保存，不通过 UI/API 暴露；hosted/self-hosted 必须绑定 credential，bare debug runtime 的 `credential_key_id` 允许为空 | `0021_runtime_channel_resume_and_admission_failures.sql`, `0029_allow_bare_runtime_channel_leases.sql` |
| `runtime_admission_failures` | RuntimeChannel HELLO/RESUME 准入失败审计；用于 Runtime Management 展示 consumed/revoked/expired credential 等启动失败原因 | `0021_runtime_channel_resume_and_admission_failures.sql` |
| `runtime_debug_datasets` | self-hosted debugger runtime 当前加载的 backtest 调试数据集元数据；真实 bars 只缓存在 runtime 内存，不入库 | `0026_runtime_debug_state.sql` |

> D3 删除了 D1 forward-compat pairing scaffold：`runtime_pairings` 会在历史迁移 `0002` 创建后由 `0009_drop_runtime_pairings.sql` 幂等删除；`PairRuntime` RPC 和 `RegisterRuntime(source=self_hosted)` 分支也已移除/拒绝。真实 self-hosted UX 是 `runtime_credentials` + RuntimeChannel。

> Phase D1 还在 `portfolio` 库的 `users` 表加了 `plan_code TEXT NOT NULL DEFAULT 'pro'`（见上面 portfolio section），control-panel-service 通过 `core-service.GetUser` gRPC 读取，不做跨库 FK。

### `{exchange}_{year}` (scraper)

行情数据只支持年库族，例如 `binance_2026` / `okx_2026`。所有年库共享同一套 schema (都是 scraper `internal/storage/migrations/` 里的文件)。`make ensure-db` 默认创建当前年的 `binance_YYYY` 和 `okx_YYYY`，也可以用 `SCRAPER_DBS=binance_2026,okx_2026` 或 `SCRAPER_EXCHANGES` + `SCRAPER_YEARS` 指定目标。

| 表 | 作用 | 首次引入 migration |
|---|---|---|
| `spot_klines` | 现货 K 线 legacy/base hypertable；实时/历史新写入会按 symbol+interval 动态建表 | `0002_create_spot_klines.sql` |
| `futures_klines` | 合约 K 线 legacy/base hypertable；实时/历史新写入会按 symbol+interval 动态建表 | `0003_create_futures_klines.sql` |
| `spot_orderbook` | 现货深度快照 legacy/base hypertable；新写入会按 symbol 动态建表 | `0004_create_spot_orderbook.sql` |
| `futures_orderbook` | 合约深度快照 legacy/base hypertable；新写入会按 symbol 动态建表 | `0005_create_futures_orderbook.sql` |
| `futures_funding_rates` | 合约资金费率 | `0006_create_futures_funding_rates.sql` |
| `futures_open_interest` | 合约 OI | `0007_create_futures_open_interest.sql` |

> 当前 scraper / strategy-library 的读写约定是：K 线按 `{market}_klines_{symbol_lower}_{interval_lower}` 动态建表；orderbook / funding / OI 按 `{market}_{datatype}_{symbol_lower}` 动态建表。实时和历史写入都必须按事件时间进入 `{exchange}_{year}` 库；固定 `binance` / `okx` 库不再是 fresh-deploy 目标，也不能作为读写 fallback。RuntimeChannel 回测通过 control-panel-service 分页读取这些 K 线表，每页最多 `8192` bars，不会把多年秒级数据一次性装入 runtime。远端旧环境里仍可能存在 `{market}_{datatype}_{SYMBOL}_{YEAR}` 表；`0008_symbol_year_partitioning.sql` 仅保留旧环境辅助函数，不作为新环境 bootstrap 目标。

## 依赖顺序

`portfolio` 必须先于其他 DB 创建,因为:

- core-service 内的 order module 通过进程内 adapter 读取 portfolio/session meta 做下单前校验 (不再通过 gRPC 回连 core-service)
- 实际 DB 层没有跨库外键,但控制面 demo/live-data 启动要求流就绪,而流是由 scraper 写的 —— 所以:
  - `control_panel` DB 必须能接受新的 market-data request / stream / lease
  - scraper 的 `{exchange}_{year}` 年库必须能接受 collector 写入

因此 `make ensure-dbs` 依次执行:

1. `core-service/make ensure-db`
2. `core-service/make ensure-order-db`
3. `control-panel-service/make ensure-db`
4. `scraper/make ensure-db`

## 添加新表 / 新迁移的约定

1. 迁移文件放在所属服务的 `internal/storage/migrations/`,文件名 `NNNN_describe.sql`(数字 4 位零填充,例如 `0010_xxx.sql`)
2. 全部语句**必须幂等** (`CREATE TABLE IF NOT EXISTS`, `CREATE INDEX IF NOT EXISTS`, `ALTER TABLE ... IF NOT EXISTS`, 等等) —— 重复运行 `make ensure-db` 不能报错
3. 新表或新列加完后**必须更新本文件的表清单**
4. 如果新表跨 DB 使用,更新上面的"依赖顺序"章节
5. 如果新字段改变 API 语义（例如 session status、错误原因、RuntimeChannel 凭证/租约），同步更新上面的"当前代码读写摘要"或对应表的说明，避免页面/排障文档和 DB 语义脱节

## 回退 / 应急

- 默认优先 additive 变更；涉及所有权迁移/废弃 scaffold 时允许显式 `DROP` migration，但必须在本文件和对应服务 README 写明迁移/回滚方式
- 要真正回滚表,写一条新的 migration 手动做 `DROP / ALTER` 然后重跑 `ensure-db`
- 紧急情况可直接 `psql`,然后在代码里把新 migration 加回当前状态以免下次 `ensure-db` 覆盖
