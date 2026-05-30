# Strategy Multi-Venue Runtime Phase 3 设计

## 背景

Phase 1 已经把 `account` 改造成 portfolio / trading context，并把具体交易所账号抽到 `venues`。Phase 2 已经把 core-service 的交易所能力边界收口到 `exchange + environment + market -> adapter`。

Phase 3 的目标不是继续做 account/venue 管理，也不是接入 OKX。Phase 3 要改的是 strategy runtime 语义：一个 strategy session 必须可以在同一个 account 下读取多个 venue wallet，并把普通订单明确路由到声明过的 `exchange + market + symbol`。

当前产品未上线，因此 Phase 3 默认 hard cut：不保留旧策略 API、旧 `market="futures"`、旧默认 Binance 快捷路径或旧单钱包 facade。

## 目标

1. 策略必须显式声明 market data 依赖和下单目标。
2. 策略 API 使用常量表达 `exchange`、`market`、`side`、`order_type`、`position_side`，避免用户直接手写易错字符串。
3. `OrderDecision` 保持为普通独立订单 API。
4. `on_market_data` 支持返回 `None`、一个 `OrderDecision` 或 `list[OrderDecision]`。
5. strategy-service 引入 `PortfolioWalletRuntime`，按 venue 隔离 wallet state。
6. strategy-service 从 core-service `PortfolioSnapshot.VenueSnapshots` 构建 runtime wallet。
7. strategy-service 用 `UpdatePortfolioSnapshot` 写回 portfolio 状态，不再用旧 `UpdateAccountWalletState` 作为正常策略运行路径。
8. 未决订单阻塞粒度为 `(account_id, exchange, market, symbol)`。
9. preflight 失败必须创建可审计的 `preflight_failed` session 记录。
10. 模板、debugger、本地调试包、README 示例全部同步新策略 API。
11. 第一轮验收使用同一个 account 下的 Binance spot venue + Binance perpetual futures venue 验证 multi-venue runtime。

## 非目标

1. 不实现 OKX demo/live 真实下单；OKX 属于 Phase 4。
2. 不实现跨交易所原子 multi-leg / arbitrage API；该能力属于 Phase 5。
3. 不引入 `OrderBatch`、`OrderLeg`、`batch_id`、`leg_id` 或 `leg_index`。
4. 不做 canonical symbol mapping；策略继续使用交易所原生 symbol。
5. 不允许同一个 account 下存在两个 active 的相同 `(exchange, market)` venue。
6. 不保留旧策略 API 兼容。
7. 不保留 `data.market[...]` 默认 Binance 快捷访问。
8. 不保留 `wallet.futures`、`wallet.spot`、`wallet.get_wallet_balance()` 等单钱包快捷接口。

## 策略 API 常量

常量定义在 `strategy-library`，并由 `strategy-service.types` 重新导出。用户模板只从 `strategy_service.types` 引入。

示例：

```python
from strategy_service.types import (
    Exchange,
    Market,
    OrderDecision,
    OrderSide,
    OrderType,
    PositionSide,
)
```

内部值仍然是字符串，例如 `Exchange.BINANCE == "binance"`，但文档和模板禁止用户直接手写 `"binance"`、`"perpetual_futures"`、`"BUY"` 等 route/enum 字符串。

必需常量：

```text
Exchange:
  BINANCE = "binance"
  OKX = "okx"

Market:
  SPOT = "spot"
  PERPETUAL_FUTURES = "perpetual_futures"
  DELIVERY_FUTURES = "delivery_futures"

OrderSide:
  BUY = "BUY"
  SELL = "SELL"

OrderType:
  MARKET = "MARKET"
  LIMIT = "LIMIT"

PositionSide:
  BOTH = "BOTH"
  LONG = "LONG"
  SHORT = "SHORT"
```

`symbol` 暂时仍是字符串，因为它是交易所原生 symbol，Phase 3 不做 canonical mapping。

## 策略声明合同

策略必须定义 `INPUTS` 和 `ORDER_TARGETS`。`ORDER_TARGETS` 即使为空也必须显式存在。

```python
INPUTS = [
    {
        "exchange": Exchange.BINANCE,
        "market": Market.PERPETUAL_FUTURES,
        "symbol": "ETHUSDT",
        "interval": "1m",
    }
]

ORDER_TARGETS = [
    {
        "exchange": Exchange.BINANCE,
        "market": Market.PERPETUAL_FUTURES,
        "symbol": "ETHUSDT",
    }
]
```

规则：

1. `INPUTS` 只表达 market data 依赖。
2. `ORDER_TARGETS` 只表达允许下单的目标。
3. `ORDER_TARGETS` 必须声明到 `(exchange, market, symbol)`。
4. `required_targets` 由 `INPUTS ∪ ORDER_TARGETS` 的唯一 `(exchange, market)` 生成，用于 preflight。
5. `market="futures"`、`future`、`perp` 等旧别名全部拒绝。
6. parser 接受常量值并 normalize 为内部标准字符串。
7. 策略返回的订单必须落在 `ORDER_TARGETS` 中，否则 strategy-service 拒绝该订单，不调用 core-service。

## 数据访问合同

旧的 `data.market[...]` 默认 Binance 快捷访问删除。

策略必须使用完整 exchange path：

```python
tick = data.exchange[Exchange.BINANCE][Market.PERPETUAL_FUTURES].symbol["ETHUSDT"].interval["1m"]
```

规则：

1. tick 只会进入声明过的 `INPUTS`。
2. 未声明 input 的 market data 被静默忽略，不进入用户策略。
3. `InputView` 不提供默认 exchange。
4. 访问不存在的 exchange/market/symbol/interval 返回 `None` 或抛出当前 accessor 定义的明确错误；不得回退到 Binance。

## OrderDecision 合同

`OrderDecision` 是普通独立订单 API，Phase 3 后仍长期保留。

最小字段：

```python
OrderDecision(
    exchange=Exchange.BINANCE,
    market=Market.PERPETUAL_FUTURES,
    symbol="ETHUSDT",
    side=OrderSide.BUY,
    qty="0.01",
    order_type=OrderType.MARKET,
    position_side=PositionSide.BOTH,
)
```

字段规则：

1. `exchange` 必填。
2. `market` 必填。
3. `symbol` 必填。
4. `side` 必填，只允许 `OrderSide.BUY` / `OrderSide.SELL`。
5. `qty` 必填，类型为字符串，必须能解析为正 Decimal。
6. `order_type` 必填。Phase 3 至少支持 `MARKET`，保留 `LIMIT` 给当前已有 limit 生命周期。
7. `price` 为 `str | None`。`LIMIT` 订单必须提供可解析 Decimal 字符串。
8. `position_side` futures-only。
9. one-way futures 可省略 `position_side`，runtime/core-service 默认 `BOTH`。
10. hedge futures 必须显式填写 `LONG` 或 `SHORT`。
11. spot 不允许填写 `position_side`。

策略可以返回：

```python
return None
return OrderDecision(...)
return [OrderDecision(...), OrderDecision(...)]
```

`list[OrderDecision]` 表示多个独立普通订单。它不是 batch，不保证全成功，也不 rollback。一个订单失败不影响同一 tick 的其他订单。

## PortfolioWalletRuntime

Phase 3 引入 `PortfolioWalletRuntime`，替代正常策略运行路径里的单 `BinanceWalletRuntime` facade。

内部结构：

```text
PortfolioWalletRuntime
  account_id
  allowed_routes: set[(exchange, market)]
  wallets:
    (exchange, market, venue_id) -> concrete WalletRuntime
```

对策略暴露：

```python
futures_wallet = wallet.get(Exchange.BINANCE, Market.PERPETUAL_FUTURES)
spot_wallet = wallet.get(Exchange.BINANCE, Market.SPOT)
```

规则：

1. 同一个 account 下 active venue 必须满足 `(exchange, market)` 唯一。
2. `wallet.get(exchange, market)` 唯一解析到一个 venue wallet。
3. `wallet.get()` 只能访问 `INPUTS ∪ ORDER_TARGETS` 中出现过的 `(exchange, market)`。
4. 未声明 route 访问直接 runtime error，并使 session 失败。
5. `PortfolioWalletRuntime` 不暴露旧单钱包快捷接口。
6. `on_market_data` 只更新 tick 所属 `(exchange, market)` wallet。
7. `on_order` / lifecycle fill 只更新订单所属 `(exchange, market, venue_id)` wallet。
8. account-level total 是聚合值，不是策略可直接操作的钱包。

Phase 3 第一轮只要求 Binance spot 与 Binance perpetual futures wallet。OKX wallet runtime 不在 Phase 3 实现。

## Snapshot 读写路径

Phase 3 正常策略运行只使用 portfolio snapshot API。

启动时：

```text
strategy-service
  -> core-service.GetPortfolioSnapshot(account_id)
  -> PortfolioSnapshot.venues[]
  -> PortfolioWalletRuntime
```

运行中：

```text
market tick
  -> update matching venue wallet

order fill / lifecycle event
  -> update matching venue wallet
  -> core-service.UpdatePortfolioSnapshot(account_id, session_id, strategy_id)
```

规则：

1. `GetPortfolioSnapshot` 是 strategy-service 构建 runtime wallet 的唯一入口。
2. `UpdatePortfolioSnapshot` 是 strategy-service 写回 wallet state 的唯一入口。
3. 旧 `GetOnlineAccountInfo` / `UpdateAccountWalletState` 不再用于正常 strategy session。
4. `PortfolioSnapshot.wallet` 只能作为 UI/兼容聚合字段，不作为 runtime 构建来源。
5. runtime 构建来源必须是 `PortfolioSnapshot.venues[]`。
6. backtest simulated venue 与 demo/live venue 使用同一种 `VenueSnapshot` shape。
7. account-level totals 由 core-service 根据 venue snapshots 聚合。
8. 如果 `PortfolioSnapshot` 缺少 required route，session preflight 失败，不启动 runtime。

## Preflight 和 Session

Preflight 输入来自 strategy-service 解析后的声明：

```text
INPUTS -> market data dependencies
ORDER_TARGETS -> order route dependencies
required_targets = unique(exchange, market) from INPUTS ∪ ORDER_TARGETS
```

Preflight 检查：

1. account 存在且未 archived。
2. account environment 合法。
3. account 当前没有 running/stopping session。
4. `INPUTS` 的 market data coverage 满足运行区间。
5. `ORDER_TARGETS` 的 active venue 存在。
6. venue/account environment 一致。
7. credential 可以解密和解析。
8. demo/live venue 可以通过 adapter 读取 account snapshot。
9. symbol 存在，symbol filters 可用。
10. required route 的 market 与 venue market 一致。

Preflight 失败：

1. 创建 `strategy_sessions` 记录。
2. 状态为 `preflight_failed`。
3. `started_at = NULL`。
4. `ended_at = now()`。
5. 写入结构化错误：`error_code`、`error_message`、`error_detail_json`。
6. UI 刷新后仍能看到失败原因。

Session 启动成功：

1. core-service 写 `session_venues`。
2. `session_venues` 记录 account 在 session start 时绑定的全部 active venues，不只记录 required targets。
3. session 仍然只绑定一个 runtime process。

## 订单校验分层

strategy-service 负责：

1. 必填字段存在。
2. `exchange` / `market` / `side` / `order_type` / `position_side` 枚举合法。
3. `qty` / `price` 是可解析 Decimal 字符串。
4. `qty > 0`。
5. order target 存在于 `ORDER_TARGETS`。
6. spot 不允许 `position_side`。
7. 未声明 target 的订单直接拒绝，不调用 core-service。

core-service 负责：

1. `account_id + exchange + market` 解析 active venue。
2. venue credential 可用。
3. account/venue environment 一致。
4. symbol 存在。
5. min qty / step size / min notional / tick size。
6. position mode / margin mode 与订单兼容。
7. exchange adapter 下单前检查。

## 生命周期隔离

未决订单阻塞粒度：

```text
(account_id, exchange, market, symbol)
```

规则：

1. strategy-service 内存里可以使用 `(exchange, market, symbol)`，因为一个 session 只属于一个 account。
2. core-service / DB / 恢复逻辑必须包含 `account_id`。
3. lifecycle event 必须带 `account_id`、`venue_id`、`exchange`、`market`、`symbol`、`position_side`。
4. fill/event 只更新对应 venue wallet。
5. terminal event 只解除对应 route 的阻塞。
6. 如果未来允许同一 account 下同 `(exchange, market)` 多 venue，再升级阻塞 key 为 `(account_id, venue_id, symbol)`。

## UI、模板和 Debugger

所有 strategy authoring 入口同步 Phase 3 hard cut：

1. Strategy create template。
2. Debugger template。
3. Debug package。
4. README 示例。
5. 本地调试示例。
6. 种子策略与测试策略。

模板必须：

1. import `Exchange`、`Market`、`OrderSide`、`OrderType`、`PositionSide`。
2. 定义 `INPUTS`。
3. 定义 `ORDER_TARGETS`。
4. 使用 `data.exchange[...]`。
5. 使用 `wallet.get(...)`。
6. 使用显式 `OrderDecision(exchange=..., market=..., symbol=...)`。
7. 不出现 `market="futures"`。
8. 不出现 `data.market[...]`。

Account detail 的 Run Strategy 页面需要展示：

1. 当前 account 绑定的 venues。
2. strategy 声明的 inputs。
3. strategy 声明的 order targets。
4. preflight 缺失项。

Session Detail 和 Order History 继续展示 venue route facts。

## 影响仓库

主要影响：

1. `strategy-library`
   - 常量/枚举。
   - `OrderDecision` 类型。
   - `InputView`。
   - 策略公开 API。

2. `strategy-service`
   - 策略声明解析。
   - `PortfolioWalletRuntime`。
   - snapshot adapter。
   - order validation。
   - multi-order return。
   - lifecycle settlement。
   - templates/debug replay/debug package。

3. `core-service`
   - preflight session failure persistence。
   - `UpdatePortfolioSnapshot` 写入语义。
   - symbol/filter preflight。
   - order lifecycle route facts。

4. `gateway/quant-handler`
   - Run Strategy preflight response mapping。
   - session/order route facts。
   - strategy declaration preview API if needed。

5. `gateway/quant-frontend`
   - Account detail Run Strategy 展示。
   - preflight failed session visibility。
   - template/editor hints。

6. `strategy-debugger-cli`
   - CLI 文档和模板说明。

## 验收范围

Phase 3 第一轮 smoke 使用：

1. 一个 backtest account。
2. account 绑定 Binance spot simulated venue。
3. account 绑定 Binance perpetual futures simulated venue。
4. 一个 strategy 声明：
   - `INPUTS`: Binance perpetual futures `ETHUSDT` `1m`
   - `ORDER_TARGETS`: Binance perpetual futures `ETHUSDT` 和 Binance spot `ETHUSDT`
5. strategy 内使用：
   - `data.exchange[Exchange.BINANCE][Market.PERPETUAL_FUTURES]...`
   - `wallet.get(Exchange.BINANCE, Market.PERPETUAL_FUTURES)`
   - `wallet.get(Exchange.BINANCE, Market.SPOT)`
   - 显式 `OrderDecision`
6. 跑通 hosted runtime backtest，第一轮浏览器 smoke 至少实际提交 perpetual futures 订单。
7. Session 状态 `FINISHED`。
8. Session Detail / Order History 显示 venue route facts。
9. 增加测试覆盖同 tick 返回两个独立 `OrderDecision` 的行为。
10. 增加测试覆盖 Binance spot + Binance perpetual wallet 不串。

不要求 Phase 3 smoke 接入 OKX。

## 测试计划

基础测试：

```bash
cd strategy-library && pytest -q
cd strategy-service && PYTHONPATH=.:../strategy-library pytest -q
cd core-service && go test ./...
cd gateway/quant-handler && go test ./...
cd gateway/quant-frontend && npm run build
cd strategy-debugger-cli && pytest -q
```

重点测试：

1. `ORDER_TARGETS` 缺失时报错。
2. `ORDER_TARGETS` 为空时允许只读策略，不允许下单。
3. 订单 target 未声明时 strategy-service 拒绝，core-service 不被调用。
4. `market="futures"` 被拒绝。
5. `data.market[...]` 不存在。
6. `wallet.get()` 未声明 route 失败。
7. `wallet.get()` 返回不同 venue wallet。
8. `qty` / `price` 字符串 Decimal 校验。
9. spot order 带 `position_side` 被拒绝。
10. hedge futures 缺 `position_side` 被拒绝。
11. `list[OrderDecision]` 独立处理。
12. lifecycle fill 更新正确 venue wallet。
13. `UpdatePortfolioSnapshot` 被调用，旧 `UpdateAccountWalletState` 不在正常 strategy session 被调用。
14. preflight 失败生成 `preflight_failed` session。
15. browser smoke 跑通 Binance spot + Binance perpetual 双 venue account。

## 实施策略

采用 Phase 3 hard-cut vertical slice。

含义：

1. 不是把 3A/3B/3C 分别作为可交付半成品上线。
2. 实现仍按依赖顺序拆任务。
3. 第一轮交付单位是完整 Phase 3 主链路。
4. 中途不保留旧兼容分支。
5. 完成后立即跑双 venue smoke。

推荐实现顺序：

1. `strategy-library` 新 API 与测试。
2. `strategy-service` declaration parsing 与 order validation。
3. `PortfolioWalletRuntime` 与 snapshot adapter。
4. multi-order return 与 lifecycle isolation。
5. core-service preflight/session failure/snapshot write 细节。
6. gateway/frontend/debugger templates。
7. 全量测试与 browser smoke。
