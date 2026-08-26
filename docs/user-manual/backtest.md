# Backtest 用户手册

最后核验：2026-08-27。

## 准备 Strategy 与 Venue

Strategy 必须声明完整 `INPUTS` 和 `ORDER_TARGETS`。同一 Strategy 可同时读取
BTCUSDT、ETHUSDT、ZECUSDT，也可为同 symbol 声明不同 interval；平台按完整
exchange/market/kind/symbol/interval 分流。

Spot Venue 不产生 Funding，也没有 leverage、position mode 或 margin mode。Futures Venue
选择 ONE_WAY 或 HEDGE，以及 Cross 或 Isolated。HEDGE 订单除 `BUY`/`SELL` 外还必须显式
给 `PositionSide=LONG|SHORT`；ONE_WAY 使用 `BOTH`。Futures leverage 只来自 Strategy：
target `leverage` → class `LEVERAGE` → 默认 `1x`。

## Funding 时间线

Futures Backtest 下载会为每个 declared input 独立准备 Kline 和 `funding_rate` coverage。
运行时在同一 market timeline 中先处理 Funding，再处理同一时刻的 Kline：平台用当时精确
LONG/SHORT legs 结算，返回 Income，Worker 应用钱包后才调用用户策略。

canonical Income 审计字段中：

- `calculated`：历史 rate、mark price 和当时持仓逐腿计算的最终 Backtest 金额；
- `actual`：Backtest 不存在交易所账单，因此为空；
- `delta`：Backtest 为零；
- `pending`：不应作为 Backtest 最终状态出现。

当前 portal 尚未提供独立 Funding Income 明细表；Session wallet 反映 applied 结果，完整
逐腿明细由平台 Income 记录保留。

若 Futures 有开放仓位且 requested window 的 Funding coverage 明确不完整，Session 以
`BACKTEST_FUNDING_DATA_GAP` fail closed；不能把缺数据当作费率零。没有开放仓位时，空
Funding row 不会自动制造结算。

## 订单语义

策略 side 只使用 `BUY`/`SELL`。当前订单行为：

- `MARKET`：立即按当前可执行流动性成交；
- `LIMIT + GTC`：未成交部分继续挂单；
- `LIMIT + IOC`：立即成交可成交部分，其余取消；
- `LIMIT + FOK`：必须立即全部成交，否则不成交；
- Futures `GTX`：post-only，若会立即吃单则拒绝；
- Spot maker 使用 `LIMIT_MAKER`。

最终可用组合仍由 route capability、symbol metadata 和风险过滤器决定。Spot 与 Futures
symbol 文本相同也不会合并 wallet/order/Funding route。
