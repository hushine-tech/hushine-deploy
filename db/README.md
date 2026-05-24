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
cd core-service       && make ensure-db         # 创建 account
cd core-service       && make ensure-order-db   # 创建 order
cd control-panel-service && make ensure-db   # 创建 control_panel (Phase D1)
cd scraper               && make ensure-db   # 创建 {exchange}_{year} 行情库
```

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
| `account` | `core-service` | 用户/账号/策略/会话/对账（Phase D2 后不再持有市场数据控制面） | [core-service/internal/storage/migrations/](../core-service/internal/storage/migrations/) |
| `order`   | `core-service/order module`   | 订单四层执行域 (intent / attempt / order / fill) | [core-service/internal/order/storage/migrations/](../core-service/internal/order/storage/migrations/) |
| `control_panel` | `control-panel-service` | Phase D1 runtime 控制面 + Phase D2 市场数据控制面 + Phase D3 self-hosted RuntimeChannel 凭证/路由 | [control-panel-service/internal/storage/migrations/](../control-panel-service/internal/storage/migrations/) |
| `{exchange}_{year}` | `scraper` | 行情数据年库族，例如 `binance_2026` / `okx_2026`；K 线 / orderbook / funding / OI 都按事件时间路由到对应年份库 | [scraper/internal/storage/migrations/](../scraper/internal/storage/migrations/) |

> `strategy-service` / `strategy-runtime` 不持有自己的表 —— 只读 `account` + 调用 core-service 承载的 `order.v1` 写 `order` + 读 scraper 的 Kafka / DB；hosted runtime 控制面状态写在 `control_panel` 由 control-panel-service 持有。

## 表清单 (按数据库分组)

### `account` (core-service)

| 表 | 作用 | 首次引入 migration |
|---|---|---|
| `schema_migrations` | 服务运行时迁移记录表 | `0000_create_schema_migrations.sql` |
| `users` | 登录用户 + bcrypt 口令；`plan_code` 字段供 control-panel-service 读取（Phase D1） | `0005_add_user_ownership.sql`, `0011_add_user_plan_code.sql` |
| `accounts` | 交易账号 (mode=0/1/2, 交易所凭据, 风控参数) | `0001_create_accounts.sql` |
| `account_snapshots` | 钱包快照 hypertable, 写入触发原因追溯 | `0002_create_account_snapshots.sql` |
| `strategies` | 策略定义 (name+version unique, immutable)；保存时记录 runtime_version/runtime_profile，供后续 runtime 版本兼容检查 | `0003_create_strategies.sql`, runtime metadata 于 `0017_strategy_runtime_debug_metadata.sql` |
| `strategy_sessions` | 策略运行 session (backtest/live/testnet/debugging), Phase D 起持久化 owning runtime (`runtime_id` / source / runtime_name)；`recoverable` 表示 runtime 失败后可恢复；`session_type` 区分 backtest/testnet/debugging，debugging session 可无 mounted strategy | `0004_create_strategy_sessions.sql`, runtime binding 于 `0013` + `0015` rename, active guardrails 于 `0014`, debug metadata 于 `0017_strategy_runtime_debug_metadata.sql` |
| `account_strategies` | 账号-策略挂载/激活关系 | `0003_create_strategies.sql` |
| `reconciliation_runs` | Phase C 对账 diff 审计 hypertable | `0007_create_reconciliation_runs.sql`, pk 调整于 `0008` |
| `notification_settings` | 用户级通知偏好和最新发送诊断；不保存消息正文 | `0016_create_notification_management.sql` |
| `notification_channels` | 通用通知通道绑定表；当前只允许 `channel=telegram`，但字段使用 target_id/type/label 以承载后续 WhatsApp/Discord 等通道 | `0016_create_notification_management.sql` |
| `notification_plans` | core-service 拥有的通知 plan 配置；复用 `users.plan_code`，不读取 control-panel-service runtime plan | `0016_create_notification_management.sql` |

> Phase D2 (2026-05-06): 市场数据控制面（`market_data_streams` / `market_data_requests` / `market_data_leases` / `market_data_history_requests`）已迁出本库，搬到了下面 `control_panel` section；historical migrations `0009_create_market_data_control_plane.sql` 和 `0010_create_market_data_history_requests.sql` 在同次提交中被删除，新增的 `0012_drop_market_data_control_plane.sql` 仅做 `DROP TABLE IF EXISTS … CASCADE` 让旧库平滑退掉这 4 张表。

### `order` (core-service order module)

| 表 | 作用 | 首次引入 migration |
|---|---|---|
| `schema_migrations` | 服务运行时迁移记录表 | `0000_create_schema_migrations.sql` |
| `legacy_order_fills` | 四层订单域上线前的历史成交表, 由旧 `order_fills` 自动改名保留 | `0001_create_order_fills.sql` → `0004_order_execution_domain.sql` |
| `order_intents` | 策略产生的交易意图 | `0004_order_execution_domain.sql` |
| `order_attempts` | 一次意图的执行尝试, 包含本地 attempt 状态、client order id 和恢复错误 | `0004_order_execution_domain.sql`, `0005_order_attempt_recovery.sql` |
| `orders` | 交易所接受后的订单, 与 attempt 一对一 | `0004_order_execution_domain.sql`, `0005_order_attempt_recovery.sql` |
| `order_fills` | 订单成交明细 hypertable, 与 order/attempt/intent 关联 | `0004_order_execution_domain.sql` |

### `control_panel` (control-panel-service, Phase D1)

| 表 | 作用 | 首次引入 migration |
|---|---|---|
| `schema_migrations` | 服务运行时迁移记录表 | `0000_create_schema_migrations.sql` |
| `runtime_registry` | 平台已知的所有 strategy-runtime；`source=hosted/self_hosted`；`role=executor/debugger`；status 状态机当前为 `paired/active/unhealthy/ended`；hosted 的 token_hash；self_hosted 行记录 credential_key_id 便于吊销；非 ended 行要求一个 credential_key_id 只能绑定一个 runtime；同一 user 的 `name` 全生命周期唯一；runtime 选择只以 `runtime_id` 为准，`name` 只是不可变展示名；connection owner 字段记录当前 RuntimeChannel owner instance；cleanup 字段记录 hosted deprovision 成败或 self-hosted 用户自管容器边界；debug workspace 字段记录 self-hosted debugger 的模板准备状态 | `0001_create_runtime_registry.sql`, `0008_add_runtime_registry_credential_key_id.sql`, `0010_unique_active_runtime_credential.sql`, `0011_allow_multiple_selected_runtimes_per_service.sql`, `0012_unique_active_hosted_runtime_slot.sql`, lifecycle rename 于 `0013_runtime_identity_lifecycle.sql`, role/owner 于 `0014_runtime_identity_role_owner.sql`, cleanup state 于 `0023_runtime_cleanup_state.sql`, debug workspace 于 `0026_runtime_debug_state.sql` |
| `market_data_streams` | 每条物理流的聚合状态 (desired/actual + live delivery) — **Phase D2 从 account 库迁入** | `0003_create_market_data_streams.sql` |
| `market_data_requests` | 用户声明的 kline 流需求 (demand-driven control plane) — Phase D2 迁入 | `0004_create_market_data_requests.sql` |
| `market_data_leases` | 活跃 mode=2 session 的 TTL 占用 — Phase D2 迁入 | `0005_create_market_data_leases.sql` |
| `market_data_history_requests` | 有限时间窗口历史数据请求/回填状态 — Phase D2 迁入 | `0006_create_market_data_history_requests.sql` |
| `runtime_credentials` | RuntimeChannel Ed25519 公钥、role、生命周期状态、下载/消费/过期/吊销审计；私钥只返回一次，不入库；hosted-internal credential 不对用户展示 secret | `0007_create_runtime_credentials.sql`, lifecycle 字段于 `0015_runtime_credential_lifecycle.sql` |
| `runtime_commands` | runtime 异步命令记录；包含 target runtime、可选 session、幂等键、状态、deadline、ack/completion 时间、payload/result/failure reason | `0016_create_runtime_commands.sql` |
| `session_market_data_subscriptions` | session 从策略 input universe 派生出的授权数据订阅；绑定 session/runtime/market/symbol/interval/mode | `0017_create_runtime_data_delivery_leases.sql` |
| `stream_delivery_leases` | Kafka/control-panel delivery worker 对 session subscription 的投递所有权租约；支持 heartbeat、expiry、steal/release，并记录最后一次投递的 topic/partition/offset/时间用于 delivery health | `0017_create_runtime_data_delivery_leases.sql`, progress columns 于 `0024_stream_delivery_progress.sql` |
| `stream_delivery_failures` | Kafka/control-panel delivery worker 的非敏感失败诊断；记录 subscription/topic/stream_key/failure_code/reason/attempt_count，供 runtime/session delivery blocked 状态排查 | `0022_create_stream_delivery_failures.sql` |
| `market_data_writer_leases` | scraper 写入 `(exchange, market, kind, symbol, interval, year)` 前必须持有的 writer lease；记录 owner/scraper/collector/lease 状态 | `0018_create_market_data_writer_leases.sql` |
| `market_data_coverage_segments` | 历史行情覆盖索引；按 `(exchange, market, kind, symbol, interval, year)` 保存连续可用区间，供 Market Data 时间轴、mode=0 backtest preflight 和 download-and-run 判断缺口 | `0025_create_market_data_coverage_segments.sql` |
| `runtime_channel_leases` | RuntimeChannel 同进程续连 token 的 hash 租约；原始 token 只在 runtime 进程内存中保存，不通过 UI/API 暴露 | `0021_runtime_channel_resume_and_admission_failures.sql` |
| `runtime_admission_failures` | RuntimeChannel HELLO/RESUME 准入失败审计；用于 Runtime Management 展示 consumed/revoked/expired credential 等启动失败原因 | `0021_runtime_channel_resume_and_admission_failures.sql` |
| `runtime_debug_datasets` | self-hosted debugger runtime 当前加载的 mode=0 调试数据集元数据；真实 bars 只缓存在 runtime 内存，不入库 | `0026_runtime_debug_state.sql` |

> D3 删除了 D1 forward-compat pairing scaffold：`runtime_pairings` 会在历史迁移 `0002` 创建后由 `0009_drop_runtime_pairings.sql` 幂等删除；`PairRuntime` RPC 和 `RegisterRuntime(source=self_hosted)` 分支也已移除/拒绝。真实 self-hosted UX 是 `runtime_credentials` + RuntimeChannel。

> Phase D1 还在 `account` 库的 `users` 表加了 `plan_code TEXT NOT NULL DEFAULT 'pro'`（见上面 account section），control-panel-service 通过 `core-service.GetUser` gRPC 读取，不做跨库 FK。

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

> 当前 scraper / strategy-library 的读写约定是：K 线按 `{market}_klines_{symbol_lower}_{interval_lower}` 动态建表；orderbook / funding / OI 按 `{market}_{datatype}_{symbol_lower}` 动态建表。实时和历史写入都必须按事件时间进入 `{exchange}_{year}` 库；固定 `binance` / `okx` 库不再是 fresh-deploy 目标，也不能作为读写 fallback。远端旧环境里仍可能存在 `{market}_{datatype}_{SYMBOL}_{YEAR}` 表；`0008_symbol_year_partitioning.sql` 仅保留旧环境辅助函数，不作为新环境 bootstrap 目标。

## 依赖顺序

`account` 必须先于其他 DB 创建,因为:

- core-service 内的 order module 通过进程内 adapter 读取 account/session meta 做下单前校验 (不再通过 gRPC 回连 core-service)
- 实际 DB 层没有跨库外键,但控制面 mode=2 启动要求流就绪,而流是由 scraper 写的 —— 所以:
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

## 回退 / 应急

- 默认优先 additive 变更；涉及所有权迁移/废弃 scaffold 时允许显式 `DROP` migration，但必须在本文件和对应服务 README 写明迁移/回滚方式
- 要真正回滚表,写一条新的 migration 手动做 `DROP / ALTER` 然后重跑 `ensure-db`
- 紧急情况可直接 `psql`,然后在代码里把新 migration 加回当前状态以免下次 `ensure-db` 覆盖
