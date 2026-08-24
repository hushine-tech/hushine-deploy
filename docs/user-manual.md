# 用户手册

最后核验：2026-08-25。

## 1. 登录与 Portfolio

登录后先创建 Portfolio。Portfolio 是 Strategy、Venue、Session 和资产/订单展示的归属
边界；一个用户可以有多个 Portfolio。

## 2. 创建 Venue

选择 Binance、环境和市场：

- Spot：钱包只保存 asset，例如 `BTC`、`ETH`、`USDT`；行情和订单使用 symbol，例如
  `BTCUSDT`。Spot 没有 leverage、cross/isolated 或 hedge 设置。
- Futures：选择 `cross` 或 `isolated` margin mode，以及页面当前开放的 position mode。
  Backtest wallet 使用 `futures.initial_balance`；杠杆由 Strategy 声明，不在 Venue 或
  Session 页面填写。
- Demo credential 通过页面绑定并由平台加密保存。页面不得显示完整 secret。

## 3. Market Data

Strategy 的 `INPUTS` 决定所需数据流。Start 前页面会逐项检查
`exchange / market / symbol / interval`。缺少时进入 Manage Streams 创建并启动对应流；
当前不会因为一个 symbol 存在就自动假定其他 symbol/interval 已准备好。

同一 Strategy 可以声明多个输入，例如 BTCUSDT、ETHUSDT、ZECUSDT，也可以为同一 symbol
声明不同 interval。完整 route 不同的数据不会合并。

## 4. Strategy

Strategy 源码至少声明：

- `INPUTS`：读取哪些行情
- `ORDER_TARGETS`：允许向哪些 route 下单

Futures target 可声明 `leverage`；未声明时读取 class-level `LEVERAGE`，仍未声明则为
`1x`。Spot target 声明 leverage 会被拒绝。订单 side 使用 `BUY` / `SELL`。

保存后先激活 Strategy，再进入 Preview。Preview 会校验源码、依赖、stream、Venue、
wallet 和 Futures 逐 target 杠杆，但不会下单或修改 Binance。

## 5. Runtime 与启动 Session

在 Runtime Management 创建 Hosted Runtime，或生成 credential 启动 Self-hosted
Runtime。只有状态为 `active` 的 Runtime 可被选择。

Start 页面会显示所选 Runtime、输入流、订单目标和风险设置。Futures 还显示每个 symbol
将采用的杠杆及来源；确认 Start 后 Demo 才允许设置并 readback Binance，全部 target
确认完成后 worker 才开始执行。

## 6. Session 观察

Session Detail 用于查看：

- 状态、bars processed、Runtime 和 Strategy 绑定
- wallet、Spot assets 或 Futures positions/UPnL
- order、fill、fee、reconciliation
- chart 和自定义 Indicator/买卖标签

Indicator 在运行中增量写入。每 1024 点封存一块；不足 1024 点的尾块会更新同一行，
没有新点时不会重复写。Session 正常结束或 worker restart 前会封存剩余尾块。

## 7. Stop、恢复与调试重启

- Stop-only：停止 Strategy，不创建平仓订单。
- Spot stop-and-close：仅处理 Strategy 声明的 Spot target，先完成整批安全预检，再卖出
  可用 base asset；任何不确定事实都会阻止发送第一张订单。
- Runtime 失联：Session 进入 `recoverable`。选择新的 active Runtime 后 Resume 会创建
  新 Session 并重新读取当前 Strategy，不把旧 Session 改回 running。
- Bare 调试：一行 restart 命令只销毁/重建 worker，agent 和 RuntimeChannel 不重启；
  旧 Session 先 finalization，再进入 recoverable。

## 8. 通知

在 Notification Management 绑定 Telegram，确认 channel 后开启需要的事件。订单成功、
失败、风险拒绝、Session lifecycle 和需要人工恢复的 Futures leverage rollback 可发送
通知。相同 recovery operation 会去重；发送失败保留平台记录以便重试。

## 9. 下单模式

- `MARKET`：按当前流动性立即成交，不指定价格。
- `LIMIT + GTC`：未成交部分继续挂单，直到成交或取消。
- `LIMIT + IOC`：立即成交可成交部分，其余取消。
- `LIMIT + FOK`：必须立即全部成交，否则全部取消。
- Spot `LIMIT_MAKER`：只挂 maker；若会立即吃单则拒绝/过期。
- Futures `GTX`：post-only；`GTD`：在指定时间前有效。

最终是否可用还取决于当前 exchange/market capability、symbol metadata 和风险过滤器；
页面或 API 的结构化错误是判断依据。
