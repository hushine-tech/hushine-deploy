# Binance Spot USDT 端到端支持设计

日期：2026-07-14

状态：设计已在对话中批准；本文档完成书面化后等待实施前最终复核

## 1. 背景

Hushine 已经在策略声明、Portfolio/Venue 路由和钱包协议中出现 Binance Spot，但当前实现并未形成
真正可用的端到端能力：

1. Demo Session 的账户快照和交易规则 reader 仍被 perpetual futures capability guard 拦截，
   Spot-only API Key 无法独立启动 Hosted worker。
2. 账户余额、行情 symbol 和订单 symbol 的语义混在一起。Binance 账户返回的是 `BTC`、`USDT`
   等资产，现有 Python Spot wallet 却可能把 `BTCUSDT` 当成资产键，导致 SELL 看不到真实 BTC，
   BUY 又写入另一份错误余额。
3. Spot 风控的生产转换没有把 Binance `balances[].free/locked` 正确放入可用余额模型，
   足额 USDT 仍可能被拒绝。
4. Spot symbol rules 没有完整进入 preflight 和 order risk gate，非法精度、步长或名义金额可能直到
   Binance 才被拒绝。
5. 离线调试包、debugger 和部分页面仍写死 perpetual futures，页面显示的 Spot 能力与实际后端能力
   不一致。
6. “停止并清仓”对 Spot 仍返回不支持，尚未落实用户已批准的 Futures 同范围语义。

本设计把 Spot 作为 Binance 标准现货账户和交易市场实现，而不是在 Hushine 内创造第二套资产命名。
它覆盖 Backtest、Demo、离线调试和真实页面；Live Spot 继续受 `environment=2` rollout guard
保护并 fail closed。

## 2. 已批准的关键决策

- 第一阶段只支持 Binance Spot 的 USDT 计价交易对。
- “只支持 USDT”限制的是可交易 symbol 的 `quoteAsset`，不是丢弃账户中的其他真实资产。
- Spot 账户资产严格使用 Binance `/api/v3/account` 返回的 `asset` 标识，例如 `BTC`、
  `ETH`、`USDT`；Spot wallet 中不存在名为 `BTCUSDT` 的资产。
- `BTCUSDT` 是交易 symbol，只存在于 market data、strategy declaration、order、fill 和 symbol
  metadata 中。它必须通过 Binance metadata 映射为 `baseAsset=BTC`、`quoteAsset=USDT`，
  禁止通过字符串去尾猜测资产。
- Binance Spot 账户快照使用官方 `GET /api/v3/account`；symbol 和规则使用官方
  `GET /api/v3/exchangeInfo`。
- Spot 和 Futures 使用 route-aware reader。Spot route 不访问 Futures endpoint，也不要求 API Key
  具备 Futures 权限；Futures route 的现有行为保持不变。
- Backtest、Demo、离线调试和 UI 支持 Spot；Live Spot 不开放，服务端 guard 是最终边界，不能只靠
  UI 隐藏。
- 用户可以选择“仅停止”或“停止并清仓”。
- Spot “停止并清仓”沿用当前 Futures 的目标范围：只处理策略声明的 Spot `ORDER_TARGETS`，
  但清理该 Venue 中这些目标对应基础资产的全部当前余额，包括 Session 启动前已有的余额。
- 目标存在 open order、余额被锁定而无法全量卖出，或全量卖出后必然留下不可交易 dust 时，
  清仓 fail closed，不自动撤单、不把 Session 伪装成已清仓。
- Spot 与 perpetual futures 可以在同一策略内同时存在；同名 symbol 必须按
  `(venue_id, exchange, market, symbol)` 隔离。

## 3. 官方 Binance 契约

本设计以 Binance 官方文档为外部真相源：

- [Spot Account Information](https://developers.binance.com/docs/binance-spot-api-docs/rest-api/account-endpoints)
- [Spot Exchange Information](https://developers.binance.com/docs/binance-spot-api-docs/rest-api/general-endpoints)
- [Spot Filters](https://developers.binance.com/docs/binance-spot-api-docs/filters)

### 3.1 账户

`GET /api/v3/account` 是签名的 USER_DATA endpoint。Hushine 至少消费：

- `canTrade`；
- `accountType` 和 `permissions`，用于记录和验证 Spot account capability；
- `balances[].asset`；
- `balances[].free`；
- `balances[].locked`。

canonical Spot asset 为：

```text
asset: Binance 资产代码，例如 BTC
free: 当前可用数量
locked: 当前被挂单或其他交易状态锁定的数量
total: free + locked（派生值，不独立回写 Binance）
```

Hushine 可以在页面隐藏零余额资产，但协议和 reader 不得把 `BTCUSDT` 等交易 symbol 转换成资产，
也不得把顶层账户字段误当成 USDT 余额。余额计算必须使用每个 `balances[]` 条目的真实
`asset/free/locked`。

### 3.2 Symbol metadata

`GET /api/v3/exchangeInfo` 返回当前交易规则和 symbol 信息。每个受支持 symbol 的 canonical
metadata 至少包含：

- `symbol`；
- `status`；
- `baseAsset`、`quoteAsset`；
- `baseAssetPrecision`、`quoteAssetPrecision`；
- `isSpotTradingAllowed`、permission sets；
- `orderTypes`；
- 原始 `filters` 集合。

一个 Spot target 只有同时满足以下条件才可进入 preflight：

1. exchange 为 Binance；
2. market 为 Spot；
3. metadata 精确匹配声明的 symbol；
4. `quoteAsset == "USDT"`；
5. `status == "TRADING"`；
6. `isSpotTradingAllowed == true`；
7. 账户与 symbol permission 允许 Spot；
8. 策略要求的 order type 位于 `orderTypes`。

仅检查 symbol 是否以 `USDT` 结尾不构成合法性验证。

### 3.3 Symbol filters

规则 reader 必须保留并类型化 Binance 返回的 filter，order risk gate 按订单类型应用至少以下规则：

- `PRICE_FILTER`：LIMIT price 的 `minPrice`、`maxPrice`、`tickSize`；
- `LOT_SIZE`：quantity 的 `minQty`、`maxQty`、`stepSize`；
- `MARKET_LOT_SIZE`：存在时用于 MARKET quantity；
- `MIN_NOTIONAL`：按 `applyToMarket` 语义校验最小名义金额；
- `NOTIONAL`：按 `applyMinToMarket/applyMaxToMarket` 语义校验名义金额范围；
- Binance 对受支持 MARKET/LIMIT order 返回的其他适用 filter。

数字计算使用十进制定点语义，不能先转 binary float 再判断模数。filter 的禁用值和 MARKET 适用条件
严格按 Binance 字段处理。遇到未知但适用于当前订单的强制 filter 时 fail closed，并返回 filter type；
不能静默忽略后继续下单。

Demo metadata 缓存按 endpoint、environment 和 symbol 隔离，默认有效期五分钟。过期时必须刷新；
刷新失败不能继续使用过期规则。一次 Session preflight 使用同一份 metadata snapshot，避免同一次
预检内部自相矛盾。

## 4. 范围

### 4.1 本轮目标

- Hosted Backtest Spot 从创建 Session 到最终钱包、订单和指标完整可用。
- Hosted Demo Spot 使用真实 Binance Demo/Testnet Spot endpoint 完成账户读取、预检、下单、生命周期
  和对账。
- strategy-debugger-cli 能离线回放 Spot，且与 Hosted Backtest 使用同一资产和规则语义。
- quant-frontend 和 quant-handler 能创建/选择 Spot Venue、展示 Spot 钱包、启动 Spot Session、
  展示订单和错误、执行两种停止动作。
- 多 input、多 symbol、多 interval 以及同一策略混合 Spot/Futures 不串流、不串钱包、不串订单。
- 所有 adapter mock 与 contract fixture 使用 Binance 官方响应形态，不再依靠仓库自定义 endpoint
  证明真实兼容。

### 4.2 非目标

- 不开放 Live Spot；所有 `environment=2 + market=spot` 请求保持 rollout-guarded、fail closed。
- 不支持非 USDT 计价的 Spot order target。
- 不支持 Margin、杠杆代币、OCO、OTO、SOR、iceberg 或自动借贷。
- 不自动把账户中的非 USDT 计价资产兑换为 USDT。
- 不自动撤销用户或其他 Session 已存在的 Spot open order。
- 不改变 Futures 的账户 endpoint、风控、清仓或路由语义。
- 不让 Runtime/worker 直接持有 Binance credential 或访问 Binance；exchange I/O 仍属于
  core-service。

## 5. 服务边界与总体数据流

```text
quant-frontend
  -> quant-handler（HTTP/JWT）
  -> strategy/control proxy
  -> core-service portfolio.v1 / order.v1
       -> route-aware Binance adapter
            Spot account:       GET /api/v3/account
            Spot symbol rules:  GET /api/v3/exchangeInfo
            Spot orders/state:  Binance Spot order endpoints

hosted runtime-agent
  -> RuntimeChannel
  -> Python session worker
       -> platform order call
       -> core-service order.v1
```

核心职责：

| 单元 | 责任 |
|---|---|
| quant-frontend | 展示真实可用能力、收集 Venue/Session/stop action、展示结构化错误 |
| quant-handler | 身份授权和请求映射；不实现 exchange 或钱包规则 |
| control-panel-service | runtime/session/market-data 控制；仅按 `runtime_id` 路由 |
| strategy-service / worker | 解析 `INPUTS`、`ORDER_TARGETS`，执行策略和维护 Session 内钱包视图 |
| core-service | Portfolio/Venue 真相、preflight、symbol rules、order risk、execution、lifecycle、reconciliation |
| Binance adapter | 按明确 route 访问正确 Spot/Futures endpoint 并转换为 canonical 模型 |

任何 Spot 修复都不能把 order execution 移回 strategy-service。所有订单继续只经过
core-service `order.v1`，并携带明确 Portfolio、Venue、exchange、market、symbol 事实。

## 6. Route-aware adapter

### 6.1 Route identity

adapter capability 解析键为：

```text
(venue_id, exchange, market, environment)
```

- `market=spot` 只构造 Spot account、Spot rules、Spot order、Spot order-state 和 Spot
  reconciliation client。
- `market=perpetual_futures` 继续构造现有 Futures client。
- `environment=0` 使用本地 deterministic reader/executor，不访问 Binance。
- `environment=1` 使用配置的 Binance Demo/Testnet Spot base URL。
- `environment=2 && market=spot` 在 capability admission 阶段直接拒绝。

不得再由 `PortfolioSnapshotReader()` 或 `SymbolRulesReader()` 内部统一调用
`requirePerpetualFutures`。接口接收并保留 route；registry 不得按 exchange 名称缓存一份跨 market
共享的 reader。

### 6.2 Spot account reader

Spot reader 只调用配置 endpoint 下的 `/api/v3/account`，完成 Binance 签名、时间同步和错误归类。
它不先调用 `/fapi/*`，也不把 Futures 请求失败当成 Spot 失败。Spot-only API Key 在具备 Spot
读取/交易权限时必须通过 Demo preflight。

reader 将所有非零 `free` 或 `locked` 的资产转换为 canonical Spot assets；零余额保留策略由展示层
决定。网络错误、签名错误、权限不足、`canTrade=false` 和响应结构错误分别返回结构化错误码，
不得折叠成 “snapshot missing”。

### 6.3 Spot rules reader

preflight 对声明的 Spot `INPUTS ∪ ORDER_TARGETS` 中所有唯一 symbol 批量读取 exchangeInfo，
并为每个 symbol 生成 metadata 和 typed filters。缺失一个目标就只报告对应 target，但整个
Session preflight 为失败；不能让部分 target 带病启动。

Backtest 和离线调试不在运行期间访问公网。调试包携带创建时取得并版本化的 Binance Spot metadata
snapshot；仓库内 deterministic fixtures 只用于测试和明确的离线 fallback，并必须保持与官方
schema 同形。

## 7. Spot wallet 契约

### 7.1 资产与交易 symbol

Spot wallet 只按 Binance asset code 保存余额：

```text
assets["BTC"]  = {free, locked}
assets["USDT"] = {free, locked}
```

market data 和 order 继续使用：

```text
symbol = "BTCUSDT"
metadata.baseAsset = "BTC"
metadata.quoteAsset = "USDT"
```

`on_market_data("BTCUSDT", price)` 只更新 BTC 以 USDT 计价所需的价格索引，不得创建
`assets["BTCUSDT"]`。wallet API 不再把含义模糊的 `symbol` 直接当 asset key；所有账本变更都携带
已解析的 base/quote metadata。

账户中的 BNB、ETH 等真实资产仍可作为资产快照存在，即使策略没有对应 ORDER_TARGET。它们可用于
Portfolio 估值，但策略只能交易 metadata 确认 `quoteAsset=USDT` 且已声明的目标。

### 7.2 BUY/SELL 账本

BUY：

1. 预占或检查 `quoteAsset=USDT` 的 free balance；
2. lifecycle 按实际 `executedQty` 增加 base asset；
3. 按实际 `cummulativeQuoteQty` 减少 USDT；
4. 按每笔 fill 的 `commissionAsset/commission` 扣除真实手续费资产；
5. NEW/PARTIALLY_FILLED/CANCELED/EXPIRED 正确调整 locked/free。

SELL：

1. 预占或检查 metadata 指向的 base asset free balance；
2. lifecycle 按实际 `executedQty` 减少 base asset；
3. 按实际 `cummulativeQuoteQty` 增加 USDT；
4. 按真实 commission asset 扣费；
5. 正确释放未成交数量的锁定。

同一 lifecycle event 使用稳定 order identity 幂等处理。重复事件不能再次扣款或加仓；迟到事件按
已有 order state machine 处理，不能覆盖更晚的 terminal 状态。

### 7.3 Wallet 路由隔离

Portfolio wallet 的实例键至少包含 `(venue_id, exchange, market)`。Spot BTC 与 Futures
BTCUSDT position 是两个不同领域对象：

- Spot wallet 中为 `assets["BTC"]`；
- Futures wallet 中为 `positions["BTCUSDT"]`。

strategy 访问 wallet 时必须带明确 exchange/market，不能通过 symbol 猜 wallet。相同 symbol 在
Spot 与 Futures 同时出现时，任何行情、order 或 lifecycle event 都只能进入其 route 对应实例。

## 8. Preflight、风控与订单执行

### 8.1 Preflight

Spot Session 启动前依次验证：

1. environment 被允许；Live Spot 立即拒绝；
2. Portfolio 中存在、启用且归属当前用户的 Binance Spot Venue；
3. account reader 成功并报告可交易 Spot capability；
4. 所有 INPUTS/ORDER_TARGETS symbol 均有合法 USDT Spot metadata；
5. 需要交易的 symbol rules 完整；
6. market-data stream 对每个 `(exchange, market, symbol, interval)` 可用；
7. strategy declaration 中 Spot target 不含 `position_side`、leverage 或 reduce-only Futures
   语义；
8. wallet snapshot 能无损转换，且不存在交易 symbol 被当成 asset 的状态。

任一失败都在 worker 启动前返回目标、route 和原因，不创建假 `running` Session。

### 8.2 Risk snapshot

生产 `OnlinePortfolioInfo -> order risk Snapshot` 转换必须逐项复制 Spot
`asset/free/locked`。BUY balance gate 查找 metadata 的 quote asset（本轮恒为 USDT）的
`free`；SELL balance gate 查找 base asset 的 `free`。locked 计入总资产但不可用于新订单。

风险校验顺序固定为：

1. route、Venue 和 environment；
2. ORDER_TARGETS 授权；
3. symbol status、Spot permission 和 order type；
4. pending execution/open-order guard；
5. price/quantity/notional filters；
6. BUY quote balance 或 SELL base balance；
7. idempotency 和 execution admission。

失败返回稳定错误码和具体字段，例如 `SPOT_QUOTE_BALANCE_INSUFFICIENT`、
`SPOT_BASE_BALANCE_INSUFFICIENT`、`SPOT_PRICE_FILTER`、`SPOT_LOT_SIZE`、
`SPOT_MIN_NOTIONAL`、`SPOT_SYMBOL_NOT_TRADING`。页面展示可操作消息，但不改写错误语义。

### 8.3 Backtest 与 Demo execution

- Backtest 使用与 Demo 相同的 canonical metadata、risk gate 和 wallet state machine，只把
  exchange executor 替换为 deterministic simulated executor。
- Demo 经 core-service Spot adapter 向 Binance Demo/Testnet 下单，策略 worker 不接触 API Key。
- MARKET 和 LIMIT 都必须覆盖 NEW、PARTIALLY_FILLED、FILLED、CANCELED、EXPIRED。
- order intent、attempt、exchange order、fill 和 wallet event 继续进入现有 order audit 链。
- exchange 拒绝与本地 precheck 拒绝使用不同 error source，便于发现规则漂移。

## 9. Reconciliation

core-service 仍是交易状态真相。Demo Spot 的对账流程按 route 单独执行：

1. 读取 Hushine 的 non-terminal Spot orders；
2. 通过 Spot order endpoint 查询状态和 trades；
3. 幂等写入缺失 fill/terminal lifecycle；
4. 重新读取 `/api/v3/account`；
5. 以 Binance asset code 对比 free/locked；
6. 更新 canonical Portfolio snapshot，并记录差异与修复来源。

Spot 对账不得触发 Futures endpoint。一个 route 的权限或网络失败只影响该 route，但包含该 route 的
Session 必须得到明确 degraded/recoverable 状态，不能继续展示已对账。exchange-backed 置信度仍需
真实 Demo smoke 和持续 reconciliation observation；单元测试不能替代。

## 10. 停止语义

### 10.1 仅停止

“仅停止”停止策略继续产生新订单，等待已接受的 lifecycle 按现有规则收口，然后结束 Session。它不
撤销 Spot open order，不卖出资产，也不改变 Session 启动前的余额。页面明确显示资产将被保留。

### 10.2 停止并清仓

“停止并清仓”采用当前 Futures 的 target scope：

1. 从该 Session 已批准的 Spot `ORDER_TARGETS` 取唯一
   `(venue_id, exchange, market, symbol)`；
2. 通过 symbol metadata 得到每个 target 的 base asset；
3. 合并指向同一 Venue、同一 base asset 的重复 target；
4. 读取停止时该 Venue 的最新真实账户快照；
5. 要求 target base asset 的 `locked == 0`，然后计划卖出其全部当前 `free`；此时 `free` 就是该
   target 的全部可见余额，并包含 Session 启动前已有资产；
6. 只使用 MARKET SELL，且仍经过 core-service `order.v1`、risk gate 和正常 lifecycle；
7. 等待 terminal fill 并重新读取账户，确认目标资产已归零后才标记清仓成功。

执行前必须对全部目标做完整 plan。以下任一条件成立时不发送任何清仓订单，并进入
`stop_failed`：

- 任一 target symbol 存在 non-terminal/open order；
- target asset 的 `locked > 0`；
- 全量余额低于适用的最小数量或最小名义金额；
- 按 MARKET_LOT_SIZE/LOT_SIZE 量化后会留下非零 dust；
- symbol 不再 TRADING、Spot trading 被禁用或 metadata/rules 不可用；
- 最新账户快照或价格/名义金额参考不可用。

零余额 target 视为已经清仓，不属于 dust。开始发送清仓订单后，如果 exchange 或 lifecycle 中途失败，
Session 进入 `stop_failed`，记录已完成和未完成目标，并立即执行账户对账；不得因为部分成功而返回
整体成功，也不得重复卖出已归零资产。

页面确认文案必须明确：

> 将卖出这些 ORDER_TARGETS 在当前 Venue 中的全部现货资产，包括策略启动前已持有的资产；不会处理
> 未声明的资产，也不会自动撤销已有挂单。

## 11. 多输入、多 interval 与混合市场

market-data stream identity 为：

```text
(stream_id, exchange, market, kind, symbol, interval)
```

不得只按 symbol 或 symbol+interval 去重。以下场景必须同时成立：

- 同一策略读取 BTCUSDT 1m 和 BTCUSDT 5m；
- 同一策略读取 BTCUSDT 与 ETHUSDT；
- 同一策略读取 Spot BTCUSDT 与 Futures BTCUSDT；
- Spot input 只读、Futures target 下单，或反向组合；
- 多个 Spot target 共享同一 USDT quote wallet，但各自使用正确 base asset 和规则。

每个行情事件只更新 metadata 对应的资产估值；每个 order decision 必须精确匹配声明的
`(exchange, market, symbol)` ORDER_TARGET。相同 symbol 的 Spot/Futures 决策不能共享
`position_side`、余额或 pending route 状态。

## 12. 离线调试

strategy-debugger-cli 和页面生成的 debug package 必须支持 Spot：

- package manifest 保留 INPUTS、ORDER_TARGETS 的 exchange/market/symbol/interval；
- package 包含版本化 Spot symbol metadata/filter snapshot；
- Spot replay 构造 Spot wallet，不再统一构造 FuturesWallet；
- 初始资产使用 Binance asset code，例如 BTC、USDT；
- BUY/SELL、MARKET/LIMIT、手续费、partial fill、locked/free 与 Hosted Backtest 同语义；
- 同一 package 可包含多 symbol、多 interval 和 Spot/Futures；
- offline mode 不访问 Binance，也不需要 Venue credential；
- Live Spot 仍不能通过 debug package 绕过 server-side environment guard。

## 13. UI 与 BFF

quant-handler 只做协议映射，不把 Spot 改写为 Futures，不为 debug package 硬编码
`perpetual_futures`。quant-frontend 必须：

- 在 Backtest/Demo 能力可用时允许选择 Binance Spot Venue；
- Live 环境不展示为可启动，直接 API 请求也由服务端拒绝；
- 展示 Spot wallet 的 asset/free/locked/USDT valuation，不显示伪资产 `BTCUSDT`；
- 订单列表明确 market=Spot，并展示 Binance symbol；
- preflight 和 execution 错误显示具体 symbol/filter/balance 原因；
- stop dialog 同时提供“仅停止”和“停止并清仓”；
- 清仓对话框展示目标 symbol、base asset、Venue 和包含既有资产的警告；
- Session 详情能区分 running、stopping、stop_failed、recoverable 和 terminal；
- mixed Spot/Futures 页面按 market 分组，避免同名 symbol 合并。

UI 显示不是 capability 真相源。所有权限、USDT quote、Live guard 和 stop scope 都必须由后端重复验证。

## 14. 错误处理与可观测性

结构化错误至少携带：

```text
code
message
venue_id
exchange
market
environment
symbol（适用时）
filter_type（适用时）
retryable
source（preflight / risk / adapter / exchange / reconciliation / stop）
```

分类原则：

- credential、permission、Live guard、非法 symbol/filter/balance 为非重试业务错误；
- 临时网络、Binance 5xx/限流和对账暂时不可用可重试，但 Session 不得假装成功；
- response schema 不匹配 fail closed，并包含 endpoint 和 schema version 日志；
- 日志必须脱敏 API key、secret、signature 和 Authorization；
- metrics 按 market/environment/error code 统计 preflight、risk rejection、exchange rejection、
  reconciliation drift 和 stop failure。

Runtime 日志中不得出现 Venue credential；worker 只看到平台订单结果和必要的 canonical wallet
snapshot。

## 15. 测试策略

### 15.1 Adapter contract

- 使用 Binance 官方 `/api/v3/account` 响应形态测试 asset/free/locked、canTrade、permissions。
- 证明 Spot reader 从不访问 `/fapi/*`，Spot-only credential 可用。
- 使用官方 `/api/v3/exchangeInfo` 形态测试 base/quote、status、permissions、orderTypes 和 filters。
- 覆盖 PRICE_FILTER、LOT_SIZE、MARKET_LOT_SIZE、MIN_NOTIONAL、NOTIONAL、未知适用 filter。
- 覆盖签名失败、权限不足、限流、5xx、schema drift、缓存过期刷新失败。
- adapter mock 不实现不存在的 `/api/v3/portfolio` 作为成功条件。

### 15.2 Wallet/risk/order

- 生产形态 snapshot 只有 `BTC` 和 `USDT`，用 BTCUSDT 行情与订单后仍只有这两个资产键。
- BUY 足额/不足 USDT；SELL 足额/不足 BTC。
- MARKET/LIMIT 的精度、步长、最小/最大名义金额。
- NEW、partial fill、full fill、cancel、expire、重复和乱序 lifecycle。
- 手续费分别由 base、quote 和 BNB 扣除。
- 风控从真实 Spot balances 读取 USDT，不使用 synthetic 顶层余额。
- order intent、attempt、fill、wallet snapshot 和最终 Binance account 可对账。

### 15.3 Backtest、Demo 与 offline

- Hosted Backtest Spot：预置 USDT 和 BTC，完成 BUY/SELL、MARKET/LIMIT、手续费和最终钱包核对。
- Hosted Demo Spot：真实 account、rules、RuntimeChannel order、lifecycle、wallet sync 和 reconciliation。
- offline debugger：对同一输入和规则得到与 Hosted Backtest 一致的 order/wallet 结果。
- environment=2 Spot 在 UI、BFF、strategy preflight 和 core capability 四层均被拒绝。

真实 Demo credential 只通过本地 secret 注入，不写入测试、日志、文档或 Git。自动化测试使用官方
schema mock；真实 smoke 作为发布验收单独运行。

### 15.4 Stop

- 仅停止保留全部 Spot 资产。
- 清仓只处理 ORDER_TARGETS，未声明资产不变。
- 清仓包含 Session 启动前已有的目标资产。
- 重复 target 指向同一 base asset 时只卖一次。
- open order、locked balance、低于 minQty/minNotional、量化后 dust 均在执行前 fail closed。
- 多 target 中一个不可清仓时不发送任何订单。
- 中途部分失败返回 stop_failed，并在对账后列出每个 target 结果。
- 零余额 target 正常成功；重试不重复卖出已归零资产。
- Futures 现有 stop-only/stop-and-close 全量回归。

### 15.5 多流与混合市场

- 同币种不同 interval；
- 不同币种相同 interval；
- Spot BTCUSDT + Futures BTCUSDT；
- 多 Spot symbol 共享 USDT；
- 不同 Portfolio 中同一 market/symbol 的 Venue 隔离；单个 Portfolio 继续遵守同一
  `(exchange, market)` 只能有一个 active Venue 的现有约束；
- market-data、wallet、order、pending state 和 UI 展示均不串路由。

### 15.6 页面验收

使用开启覆盖率的本地完整系统和真实浏览器执行：

1. 创建或复用 Binance Demo Spot Venue；
2. 查看 /api/v3/account 对应资产；
3. 创建包含 Spot INPUTS/ORDER_TARGETS 的策略并通过预检；
4. 运行 Hosted Spot Backtest，核对订单、fill、钱包和图表；
5. 运行 Hosted Spot Demo，核对 Binance 与 Hushine 数据；
6. 运行多 symbol、多 interval、Spot/Futures 混合策略；
7. 分别执行仅停止和停止并清仓；
8. 验证 open order/dust 的 stop_failed 页面；
9. 下载并运行 Spot offline debug package；
10. 验证 Live Spot 无法启动；
11. 导出服务与 Runtime coverage，检查未覆盖的 Spot 分支。

### 15.7 常规回归

- 每个 Go 仓库执行 `go test ./...` 和 `go vet ./...`；
- strategy-service 执行 Python、Go 和 tracked shell tests；
- strategy-library 与 strategy-debugger-cli 执行各自 pytest；
- quant-frontend 执行 build 和全部 `scripts/*.test.mjs`；
- 根目录执行数据库、构建、启动和集成测试；
- Futures 回测、Demo、最大亏损/爆仓、订单生命周期、通知、Runtime 心跳和 worker restart 回归。

## 16. 部署与回滚

### 16.1 发布顺序

1. 先发布 core-service：route-aware Spot account/rules、risk、execution、reconciliation；
2. 再发布 strategy-library、strategy-service 和 Runtime 镜像：canonical Spot wallet 与 Hosted flow；
3. 再发布 strategy-debugger-cli 和 debug package generator；
4. 再发布 quant-handler；
5. 最后发布 quant-frontend，解除 Backtest/Demo Spot 的 false-disabled 状态；
6. 使用 Demo Venue 完成真实页面 smoke 后才把 Demo Spot capability 标记可用。

接口变更采用向后兼容的 additive deployment；如果 canonical metadata 需要新增 proto 字段，先部署
reader，再部署 consumer，最后才停止写旧兼容字段。数据库如需增加 symbol metadata/filter snapshot，
只做 additive migration，不删除 Portfolio、Venue、订单、fill 或钱包历史。

### 16.2 Guard

Spot capability 分为：

- `backtest_spot_usdt`；
- `demo_spot_usdt`；
- `offline_spot_usdt`；
- `live_spot_usdt`。

前三个在验收通过后启用；`live_spot_usdt` 保持关闭。即使配置误开，现有
`environment=2` rollout guard 仍必须阻止 Live Spot admission。

### 16.3 回滚

若真实 Demo 出现账户、规则、订单或对账问题：

1. 关闭 Demo Spot capability，阻止新 Session；
2. 保持查询和 reconciliation 运行，收口已创建订单；
3. 不回滚或删除订单、fill、钱包审计数据；
4. 已运行 Session 转为明确 recoverable/failed，不伪装成功；
5. 回滚 UI/BFF 后，core-service 仍保留 Spot lifecycle/reconciliation 直到所有订单 terminal。

Backtest/offline 与 Demo capability 可独立关闭，回滚 Spot 不影响 Futures。

## 17. 验收标准

实现只有同时满足以下条件才算完成：

1. Spot-only Demo API Key 可以启动 Hosted Spot worker，不需要 Futures 权限。
2. Spot account reader 只使用 `/api/v3/account`；rules reader 使用
   `/api/v3/exchangeInfo`。
3. 所有可交易 target 都由 metadata 证明 `quoteAsset=USDT`，不以字符串后缀代替校验。
4. Spot wallet 只包含 Binance asset code；任何路径都不会创建 `BTCUSDT` 资产。
5. BUY/SELL、MARKET/LIMIT、balance 和 Binance filters 在 Backtest、Demo、offline 中语义一致。
6. core-service order.v1 是唯一订单执行入口；Runtime/worker 不持有 exchange credential。
7. 多 symbol、多 interval、Spot/Futures 和多 Venue 不串路由。
8. stop-only 保留资产；stop-and-close 只处理 ORDER_TARGETS，但包含 target 的既有全部持仓。
9. open order、locked balance 和 dust 均 fail closed，页面明确显示原因。
10. Live Spot 在前后端直接请求和内部调用中均被 environment guard 拒绝。
11. Binance Demo 真实页面链路通过，并完成 order/fill/wallet/account 数据校对。
12. AGENTS.md 规定的常规测试与 Futures 回归全部通过。
13. 覆盖率报告包含 adapter、wallet、risk、order、stop、mixed route、offline 和 UI 关键分支。
14. 文档、Mock、页面文案和实现使用同一 Binance 资产/symbol 术语，没有旧的伪 endpoint 或
    Futures-only Spot 说明。

## 18. 实施约束

- 以 TDD 实施：先加入生产形态失败测试，再修改实现。
- 不通过删除或放宽现有 Futures 测试让 Spot 变绿。
- 不根据当前 Mock 反向定义 Binance 契约；Mock 必须追随官方契约。
- 不用 symbol 字符串切割代替 metadata。
- 不在多个服务复制不同版本的 Spot filter 逻辑；core-service 是交易规则权威。
- 不把展示层余额作为风控真相；风控只读 core-service canonical snapshot。
- 每个工作包完成后做独立代码 review，最终用真实浏览器和真实 Demo 重新验证。
