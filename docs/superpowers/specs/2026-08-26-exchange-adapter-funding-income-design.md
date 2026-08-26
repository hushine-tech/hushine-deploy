# Exchange Adapter Funding Income 设计

日期：2026-08-26

状态：设计已在对话中批准；等待用户对书面版本复核后编写实施计划

## 1. 背景

Hushine 当前能够通过订单成交更新 Futures 钱包、手续费和已实现盈亏，但没有完整的 Funding Fee
链路：

1. Binance Futures User Data Stream 目前只接受 `ORDER_TRADE_UPDATE`；收到
   `ACCOUNT_UPDATE` 会返回“不支持的事件”并触发重连。
2. User Data Stream 当前从未完成订单反推需要监听的 Venue。用户持有仓位但没有挂单时，账户流可能
   根本没有启动。
3. core-service 没有 Binance Income History reader，也没有 `tranId` 去重或 Funding Income 持久化。
4. scraper 已保存历史 Funding Rate、Funding Time 和 Mark Price，但当前代码把下一次结算时间硬编码为
   `fundingTime + 8h`；交易所可能调整结算间隔，该推导不可靠。
5. strategy-service 的 canonical wallet 已有应用 ledger event 的基础能力，但生产链路没有向它投递
   Funding Income；`marketdata_adapter` 也没有提供 Funding Rate。
6. 当前数据库没有 `income_type`、`tran_id` 或 Binance Income 表。已实现盈亏来自订单成交，而不是
   Income History。

本设计补齐 Backtest、Demo 和 Live 的 Funding Fee，同时保持现有订单、RuntimeChannel、Session 和
Exchange Adapter/Registry 边界。`strategy-debugger-cli` 从本次开始停止维护，不纳入本功能。

较早的日期化设计和计划仍作为历史记录保留；其中要求继续扩展 `strategy-debugger-cli`，或使用固定
8 小时 Funding 间隔的内容，被本设计的当前决策取代，不能再作为实施依据。

## 2. 已批准的产品语义

- Funding Fee 只适用于 Futures；Spot 不产生 Funding Fee。
- Backtest、Demo 和 Live 使用同一个通用调度框架，以及同一交易所 Adapter 提供的计算实现。
- One-way、Hedge、Cross 和 Isolated 均支持。
- Hedge 模式必须先分别计算 LONG/SHORT 持仓腿，再汇总；禁止先净额合并后计算。
- Cross 与 Isolated 不改变资金费公式，只改变金额归属的钱包位置和风险明细。
- 只支持 USDT 结算的线性 Futures；其他结算资产由 Adapter fail closed。
- 杠杆不直接进入 Funding Fee 公式；它只影响用户能够建立的仓位规模。
- Demo/Live 以交易所 Income History 返回的实际金额为最终值；平台计算值用于逐腿明细和核对。
- Backtest 使用历史 `fundingTime + fundingRate + markPrice + 当时持仓` 计算最终值。
- Funding Fee 只归属于发生时正在运行的 Session。没有匹配 Session 的账户变化视为离线变化，既不
  写 Session Income，也不改变策略钱包。
- 同一个 Venue 可以先后用于多个 Session，因此 Income 必须显式保存 `session_id`。
- 订单表仍然只保存订单、成交、手续费和由成交产生的 `REALIZED_PNL`；Funding Fee 不写订单表。
- 数据库只新增一张通用 `venue_income_entries` 表，不新增 Funding 子表或钱包流水表。
- 现有 `venue_wallet_states` 继续保存 Venue 当前钱包状态。
- `strategy-debugger-cli` 不实现 Funding Fee，不再进入常规功能验收和维护矩阵，后续再单独决定删除。

## 3. 术语与边界

### 3.1 Exchange Adapter 就是现有 Plugin 机制

本设计中的交易所插件指现有的 Exchange Adapter/Registry：

```text
core-service/internal/exchange/adapter
core-service/internal/exchange/adapter.Registry
core-service/internal/exchange/binance.Factory
core-service/internal/exchange/okx.Factory
```

不引入第二套 Plugin 框架，不使用动态 `.so` 加载，也不增加与现有 Registry 平行的路由。

scraper 同样继续使用其现有 `internal/exchange.Registry`。Funding Collector 的交易所接口、URL 和
字段解析必须位于对应 Exchange Adapter 下。

### 3.2 通用层与 Adapter 的职责

通用 core-service 可以处理：

- Session/Venue 所有权和运行时间区间；
- 调度、重试、限频、错峰和重连补查；
- canonical User Data Event、Income Entry、Position Leg 和 Settlement Result；
- 数据库事务、唯一约束、钱包状态更新和 Runtime 投递；
- capability unsupported、retryable 和 fail-closed 行为。

Exchange Adapter 必须处理：

- 交易所 REST/WebSocket URL、认证、签名、限频头和错误码；
- Binance `ACCOUNT_UPDATE`、`ORDER_TRADE_UPDATE`、`m`、`incomeType`、`tranId` 等私有字段；
- 交易所事件到 canonical event 的映射；
- Income History 查询和分页；
- 合约面值、正负方向、结算资产、舍入规则及交易所特有 Funding 公式；
- 交易所 Funding Market Data 的字段解析。

通用代码不得出现 `if exchange == Binance`，也不得直接导入 Binance package。调用固定为：

```text
route -> adapter.Registry -> capability -> canonical result
```

### 3.3 strategy-service 边界

strategy-service 不访问 Binance/OKX REST 或 WebSocket，不解析 `ACCOUNT_UPDATE`，也不计算交易所
Funding 公式。它只接收 canonical Income Event：

```text
session_id
venue_id
exchange
market
income_type
symbol
asset
signed_amount
position_legs
occurred_at
income_entry_id
```

Wallet Runtime 根据 route registry 将结果应用到相应交易所钱包实现。以后增加 OKX Wallet Adapter 时，
通用 Strategy Engine 和 RuntimeChannel 事件处理不改变。

## 4. Adapter 能力设计

现有 `UserDataStream` 只返回 `UserDataOrderEvent`，需要提升为 canonical User Data Event stream，而不是
再建立一条重复的账户 WebSocket。

### 4.1 UserDataEventStream

标准事件为带判别字段的 union：

```text
UserDataEvent
  kind = order_update | account_update
  event_time
  transaction_time
  order_update?
  account_update?
```

`account_update` 至少包含：

```text
reason
changed_balances
changed_positions
raw_reference
```

Binance Adapter 将外部原因映射到 canonical reason。通用层认识 `order`、`funding_fee` 和
`other`，但不认识 Binance 的原始 JSON 路径。未支持原因不得使 stream 退出或重连。

### 4.2 IncomeHistoryReader

标准请求包含 route、credential、income type、起止时间和分页游标；标准结果包含：

```text
external_transaction_id
income_type
symbol
asset
signed_amount_decimal
occurred_at
raw_payload
```

Binance 实现固定用 `incomeType=FUNDING_FEE` 查询 `/fapi/v1/income`，并保留原始 `tranId`。以后 OKX
实现相同 capability，通用 Coordinator 不增加分支。

### 4.3 FundingSettlementCalculator

标准请求包含：

```text
route
funding_time
funding_rate_decimal
mark_price_decimal
settlement_asset
margin_mode
position_mode
position_legs[] { symbol, position_side, signed_qty_decimal }
```

标准结果包含逐腿金额、汇总金额、精确十进制文本和 Adapter 版本。公式与舍入属于 Adapter。

Binance USDT 线性合约的当前规则由 Binance Adapter 实现：

```text
leg_amount = -signed_quantity * mark_price * funding_rate
```

LONG quantity 为正，SHORT quantity 为负。该公式不得复制到 Coordinator 或 strategy-service。

### 4.4 FundingMarketDataCollector

scraper 的 Exchange Adapter 输出 canonical：

```text
exchange
market
symbol
funding_time
funding_rate_decimal
mark_price_decimal
next_funding_time?
```

历史 Funding Row 的 `funding_time` 使用交易所真实值。不得再用固定 `+8h` 推导下一次时间：批量历史
响应使用下一条真实 Funding Time；最新调度使用交易所当前 Funding/Premium 数据提供的
`nextFundingTime`。无法取得时保持未知并重试，不能伪造。

## 5. User Data Event 分流

`ACCOUNT_UPDATE` 是传输事件，不是数据库表模型：

```text
UserDataEventStream
  ├─ order_update
  │    -> 现有订单/成交链路
  └─ account_update
       ├─ reason=order
       │    -> 更新/核对 canonical 持仓投影，不写 Income
       ├─ reason=funding_fee
       │    -> 触发 Funding Income sync
       └─ other
            -> 状态更新或告警，不写 Funding Income
```

一次成交可能同时产生 Order Update 和 `account_update(reason=order)`。Order Update 是订单事实的唯一
来源；Account Update 只提供账户/持仓核对，不能再次生成成交或重复计算 `REALIZED_PNL`。

`account_update(reason=funding_fee)` 没有最终 `tranId`，所以它只是实时触发器和持仓时点信号。最终
Income Entry 必须来自 IncomeHistoryReader。

## 6. 持仓时点与逐腿计算

### 6.1 Demo/Live

Session 启动时保存权威账户初始快照。运行期间，通用持仓投影由 canonical
`account_update(reason=order)` 和订单事实持续推进。

同一连接内同类型 Account Update 按交易所事件顺序处理。收到 Funding Account Update 时，Coordinator
冻结 Funding 发生前的持仓投影：

- One-way 保存 `BOTH`；
- Hedge 分别保存 `LONG` 与 `SHORT`；
- Cross Funding Event 即使没有 Position Payload，也使用此前维护的持仓投影；
- Isolated 保存相应 isolated position 和钱包归属。

如果 WebSocket 断线，使用 Session 初始持仓加该 Session 的订单成交事实，按事件时间重建 Funding 时刻
的持仓。平台要求 Venue 对应的 Futures 账户在 Session 期间专用；检测到无法归属于平台订单的外部
变化时进入 reconciliation warning/fail-closed，而不是静默猜测。

### 6.2 Backtest

Backtest 市场时间到达 `funding_time` 时，必须在同一时间点的下一次策略 Kline 回调之前结算：

1. Runtime 将 canonical Funding Fact 与当前持仓快照提交到平台；
2. core-service 验证 Session、Venue、route 和市场时间；
3. Coordinator 从 Registry 取得对应 Exchange Adapter calculator；
4. Adapter 返回逐腿及汇总结果；
5. Repository 写 Income 并更新现有钱包状态；
6. Worker 应用平台返回的 signed amount；
7. 完成后才允许策略看到下一根 Kline。

Worker 不实现 Funding 公式。用户代码阻塞时 Backtest 模拟时间本身暂停，因此不会越过 Funding 时点；
Runtime Agent 心跳和控制通道仍然必须独立存活。

## 7. Income 数据模型

数据库只新增一张 `venue_income_entries`。逻辑字段为：

```text
income_entry_id          internal primary key
session_id               required
venue_id                 required
income_type              required
source                    exchange | backtest
external_transaction_id  Demo/Live exchange transaction id; Backtest null
settlement_key            deterministic logical settlement identity
symbol
asset
occurred_at
calculated_amount
exchange_amount           nullable for Backtest/pending records
applied_amount
reconciliation_delta      exchange_amount - calculated_amount
calculation_details       JSON array of position legs and exact inputs
raw_payload               exchange response; empty object for Backtest
status                    pending_actual | confirmed | calculated
created_at
updated_at
```

`calculation_details` 保留每个 LONG/SHORT leg：side、margin mode、quantity、mark price、rate、amount 和
calculator version。一个 Funding settlement 按 Session/Venue/Symbol/Funding Time 保存一行，腿明细不再
拆表。所有 Funding 记录都必须有版本化的 `settlement_key`；它由 canonical route、Session、Venue、
symbol、asset 和真实 Funding Time 确定，不使用查询时间或数据库自增 ID。

### 7.1 Session/Venue 约束

```sql
session_id TEXT NOT NULL,
venue_id   BIGINT NOT NULL,
FOREIGN KEY (session_id, venue_id)
    REFERENCES session_venues(session_id, venue_id)
```

同一 Venue 可先后属于多个 Session，不能只靠 `venue_id` 推断归属。

Income 的 `occurred_at` 必须落在 Session 的半开运行区间：

```text
started_at <= occurred_at < completed_at
```

活动 Session 的 `completed_at` 视为无穷。迟到查询按 Income 发生时间关联原 Session，不按查询发生时的
当前 Session 关联。找不到匹配 Session 的记录视为离线账户变化并忽略。

### 7.2 唯一约束

Demo/Live 以交易所实际 ID 防重。PostgreSQL 使用条件唯一索引，而不是带 `WHERE` 的表级
`UNIQUE` 约束：

```sql
CREATE UNIQUE INDEX ...
ON venue_income_entries (venue_id, income_type, external_transaction_id)
WHERE external_transaction_id IS NOT NULL;
```

Backtest 与 pending settlement 使用 deterministic key：

```sql
CREATE UNIQUE INDEX ...
ON venue_income_entries (session_id, venue_id, income_type, settlement_key);
```

`session_id` 不进入交易所 ID 唯一键，防止同一迟到 Income 被下一 Session 再次入账。

Demo/Live 的合并顺序固定为：

1. Account Update 或公开 Funding Time 可先按 `settlement_key` 建立 `pending_actual`，但不更新钱包；
2. Income History 返回后先按 `(venue_id, income_type, external_transaction_id)` 查找；
3. 没有命中时，再按 Income 的 `occurred_at` 关联原 Session，并用该 Session 的 `settlement_key` 查找；
4. 命中 pending 时，在同一事务内补上 `external_transaction_id`、实际金额和原始响应，并转为
   `confirmed`；
5. 两个键都未命中时直接插入 `confirmed`；两个键命中不同记录时属于数据冲突，fail closed，禁止自动
   合并或重复入账。

这样，实时触发先到、REST 账单先到、重复推送和并发轮询都会收敛到同一行。

### 7.3 通用 Income 与订单边界

本次只查询和处理 `FUNDING_FEE`。以后支持 `COMMISSION_REBATE`、`INSURANCE_CLEAR`、`TRANSFER` 等
非订单账户收支时，继续扩展本表的 `income_type` 与 Adapter handler，不新增专表。

`REALIZED_PNL`、订单 commission 和 fill 仍以订单链路为权威，本轮不从 Income History 导入，避免
重复入账。`MARGIN_TYPE_CHANGE` 等没有金额的状态事件不属于 Income。

## 8. 原子入账和钱包更新

`venue_income_entries` 本身就是账户收支历史，不新增钱包流水表。`venue_wallet_states` 保存当前状态。

Repository 在同一事务中：

1. 锁定 Session、Session Venue 和当前 Venue Wallet；
2. 插入或确认 Income Entry；
3. 只有首次进入可应用状态的 Entry 才把 `applied_amount` 应用到钱包；
4. 更新 `venue_wallet_states`、Portfolio 汇总和必要的 Session snapshot；
5. 提交后再发送 Runtime/notification outbox；
6. 任一步失败则全部回滚。

重复 WebSocket、定时查询、重连补查或并发 worker 只能命中同一唯一键，不能重复更新钱包。

Demo/Live 使用交易所实际 Income amount 更新策略钱包；计算值不先临时扣款。Backtest 直接使用
Adapter calculated amount。Account Update 本身不产生最终 Income，也不单独再次加减钱包。交易所
账户快照可以用于风险门控和 reconciliation，但若该快照已包含 Funding 变化，不得再把快照差额作为
第二笔 Income 应用。

## 9. Demo/Live 同步策略

IncomeHistoryReader 只服务活动或刚结束且仍在结算 grace window 内的 Session Venue。Session 结束后，
直到所有已检测 pending 均确认且至少一次最终重叠查询成功才可停止；硬上限为 24 小时。到达上限仍有
pending 时标记为不可自动恢复并告警，不得静默丢弃或将它关联到下一 Session。

触发规则：

1. 收到 canonical `account_update(reason=funding_fee)` 后立即查询；
2. 尚未出现实际 Income 时，在 10 秒、30 秒、1 分钟、2 分钟、5 分钟重试；
3. 到达公开 `nextFundingTime + 10s` 时，即使没有推送也主动查询；
4. Session 启动、User Data Stream 重连和服务重启后立即补查；
5. 正常运行期间每 15 分钟查询一次，并加入随机错峰；
6. 每次从持久化 watermark 前 24 小时开始重叠查询；
7. 分页读取到结尾，使用唯一键消除重叠结果；
8. 遵守 Adapter 返回的限频信息并使用全局 limiter、指数退避和 jitter。

Binance 普通 Income History 当前请求权重为 30，默认返回最近 7 天，最多只保留最近 3 个月。服务重启
恢复不得依赖超过交易所保留范围的数据；超过范围必须显式报告不可恢复。

## 10. Runtime 解耦

Demo/Live Funding Coordinator、User Data Event Stream 和 Income Poller 运行在平台服务内，不运行在用户
Session Worker 线程中。因此用户断点或长循环不得影响：

- Runtime Agent 心跳；
- Account Event 接收；
- Income 查询与去重；
- 数据库入账；
- Session 状态和通知。

Worker 阻塞期间，平台保存 canonical Income Event。Worker 恢复后按 `income_entry_id` 顺序补投，Worker
也按该 ID 幂等应用。不能因为 Worker 暂时不可用而把平台已确认 Income 回滚。

Backtest 只在模拟时间推进时触发 Funding；用户代码阻塞意味着模拟时间未推进，不影响 Agent 心跳。

## 11. 失败与安全语义

- Exchange Adapter 缺少所需 Funding capability：对应 Futures Session preflight fail closed。
- Backtest 有非零持仓但缺 Funding Rate 或 Mark Price：Session 失败，禁止默认为零。
- Demo/Live Income 查询暂时失败：Entry/settlement 保持 pending，按计划重试。
- 可以确认交易所钱包但暂时缺 Income 明细：允许继续运行并标记 reconciliation pending。
- 钱包与 Income 都不可用：阻止新增风险仓位，只允许撤单、reduce-only 和平仓，并通知用户。
- 收到未支持 Account Update reason：不写 Income，记录 metric/告警，stream 继续运行。
- 交易所返回非法 decimal、缺少 transaction ID、币种不一致或非 USDT settlement：fail closed，原始响应
  脱敏保存到错误上下文。
- 实际金额与计算金额不一致：以实际金额更新 Demo/Live 钱包，保存 delta 和逐腿明细并告警；不得覆盖
  或删除计算记录。
- 检测到 Session 期间外部/手工账户变化：进入 reconciliation warning；无法确定策略钱包时阻止新增
  风险仓位。

## 12. 测试与验收

### 12.1 Adapter contract

- Binance Adapter 解析交错的 Order Update 与 Account Update；非订单事件不再触发重连。
- Binance Income request、签名、`incomeType=FUNDING_FEE`、分页、超时、重试和限频测试。
- Funding Calculator exact-decimal 输入输出和舍入测试。
- 注册 Fake OKX Adapter 后，通用 Coordinator 通过同一测试套件，且 common package 不增加 Binance
  import/switch。
- OKX 真实 capability 仍保持 fail closed，直到 OKX Adapter 单独实现。

### 12.2 计算矩阵

- One-way LONG/SHORT，正负 Funding Rate；
- Hedge LONG/SHORT 分腿、同 symbol 双向仓位；
- Cross/Isolated；
- 多 symbol Session；
- 零仓位、Funding 前平仓、Funding 后开仓；
- Funding 时刻的 partial fill、full fill、liquidation 和 ADL；
- leverage 不进入公式；
- USDT settlement constraint；
- exact decimals，无 float 作为权威金额。

### 12.3 时间和恢复

- Backtest Funding 在同时间 Kline 回调之前；
- Funding 前后成交使用正确持仓；
- 不固定 8 小时间隔；
- 正常推送、无推送、延迟推送、断线漏事件；
- 推送与 poll 同时返回、服务重启、Income 延迟 5 分钟；
- 两个 Session 顺序复用同一 Venue；
- 旧 Session Income 在新 Session 期间迟到；
- 无 Session 的离线 Income 被忽略；
- 超过 3 个月保留范围明确失败。

### 12.4 数据库

- Fresh database 从 current baseline 一次创建成功；
- 只新增 `venue_income_entries`，订单表不变；
- Session/Venue composite FK；
- 交易所 ID 和 settlement key 唯一约束；
- 并发插入只应用一次钱包；
- pending 后收到实际账单、实际账单直接到达，以及两个唯一键冲突的状态机测试；
- Income、Venue wallet、Portfolio aggregate 原子提交和故障回滚；
- provisional/confirmed 状态转换不重复应用；
- raw payload 和 calculation details 均为合法 JSON object/array。

### 12.5 Runtime 与回归

- 阻塞 Worker 时 Agent 心跳、Account Stream、Income Poller 和数据库入账继续；
- Worker 恢复后 Income 只应用一次；
- Funding 错误不使 Runtime Agent 或 Worker 进程意外退出；
- Futures GTC、IOC、FOK、GTX/Post-only、Market 订单回归；
- One-way、Hedge、Cross、Isolated、多 symbol、liquidation、ADL 回归；
- Spot 全链路不产生 Funding Income；
- 全仓库构建、测试、静态检查和 coverage instrumentation 继续通过；
- Mock Binance 支持可编排的 Funding Account Update、延迟 Income、重复事件、分页和失败注入；
- 最后执行 Binance Demo 环境真实冒烟测试。

`strategy-debugger-cli` 不进入本测试矩阵。

## 13. 数据库与部署原则

系统尚未正式上线，不增加旧 Income schema、双写、dual read 或兼容 fallback。直接把当前唯一模型写入
core-service 的 `0001_current_schema_baseline.sql`，并同步 `db/README.md` 与 repository contract test。

部署验收必须从空数据库一次拉起全部 current tables/indexes/constraints，并验证服务可读写。现有本地
测试数据可以清空重建。

## 14. 非目标

- 本轮不实现 OKX 的真实 Funding API；只保证 Adapter capability 可替换且 OKX 缺失时 fail closed。
- 本轮不从 Income History 导入 `REALIZED_PNL`、commission 或全部 Binance 账户历史。
- 本轮不支持 Spot Funding、COIN-M、非 USDT 结算或 Portfolio Margin 特殊产品。
- 本轮不维护或扩展 `strategy-debugger-cli`。
- 本轮不把用户在 Session 外的 Binance 收支纳入策略业绩。
- 本轮不为每种 Income Type 建独立表。

## 15. 完成标准

以下条件全部满足才可声明完成：

1. 三种环境使用一个 Coordinator 和各 Exchange Adapter 的单一计算实现；
2. Binance 私有接口与计算规则未泄漏进通用 core/strategy 逻辑；
3. Demo/Live 在推送丢失时能按计划主动发现并入账；
4. `tranId`/settlement key 幂等和数据库事务经并发测试；
5. Hedge 逐腿明细、实际值、计算值和 reconciliation delta 均可查询；
6. Worker 阻塞不影响平台 Funding 处理和 Agent 心跳；
7. 订单与 Spot 回归全部通过；
8. 空库一次部署成功；
9. Binance Demo 真实冒烟通过，或明确记录唯一剩余的外部环境阻塞证据。
