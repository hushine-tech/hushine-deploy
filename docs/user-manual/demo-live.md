# Demo / Live 用户手册

最后核验：2026-08-27。

## 当前范围

Binance USDT 线性 Futures Demo 支持 Funding；Spot 不产生 Funding。OKX Funding capability
仍 fail closed。Live 代码路径继续受 rollout guard 保护，页面或 API 不能绕过。Demo
credential 只在 Venue 页面绑定并由平台加密保存；Runtime/Worker 不会收到 key/secret。

Futures Venue 选择 ONE_WAY 或 HEDGE、Cross 或 Isolated。HEDGE order 使用
`BUY`/`SELL` 并显式提供 `PositionSide=LONG|SHORT`；ONE_WAY 使用 `BOTH`。杠杆只来自
Strategy target/class，未声明时为 `1x`，不直接进入 Funding 公式。

## Funding Income 与 reconciliation

Funding Account Update 只是实时触发器；平台随后查询 Income History，以交易所 actual
amount 和 transaction ID 确认最终账单。没有推送时，周期/重连 repair 仍会发现账单。

canonical Income 审计字段：

- `actual`：交易所账单，Demo/Live 钱包实际应用值；
- `calculated`：平台按真实 Funding fact 和逐腿持仓算出的审计值；
- `delta`：`actual - calculated`，非零时保留并告警，不覆盖 calculated；
- `pending`：已知 settlement，但 actual 尚未出现；pending 不更新策略钱包。

当前 portal 尚未提供独立 Funding Income 明细表；Session wallet 只显示 applied 结果，
actual/calculated/delta/pending 的完整记录由平台保留。

Cross 与 Isolated 使用同一公式，但金额应用到对应钱包位置。HEDGE 的 LONG/SHORT 必须分别
计算，不能先净额。多 symbol Session 的 Income 按 Venue/symbol/发生时间独立入账；同一
Venue 被后来 Session 复用时，迟到账单仍归属原 Session。

## 订单与恢复

当前支持 MARKET，以及 LIMIT 的 GTC/IOC/FOK；Futures GTX 是 post-only。交易所实际
capability、symbol filters、余额/仓位与风险门禁可能进一步拒绝组合。Spot order 不设置
PositionSide，也不会触发 Funding。

用户命令触发 worker-only restart 时，旧 Worker 先 finalize，旧 Session 变为
`recoverable`，Go Agent/RuntimeChannel 保持运行，再创建新 Session ID 并加载当前策略。
Income replay 通过持久化 wallet cursor 幂等；不要在数据库中把旧 Session 改回 running。

## Telegram 与当前限制

在 `Notification Management`：

1. 生成 bind code；
2. 把最新 code 发送给页面显示的 bot；
3. 返回页面确认 binding；
4. 开启 master switch 及允许的 system/strategy/custom 分类；
5. 发送 test notification，并检查 last delivery status/error。

Plan、用户偏好、channel binding 或 sender 任一未就绪时，delivery 会延后或失败并保留状态。
当前没有独立的 Funding Income 用户通知类别；Funding pending/delta/grace 先由平台 Income
状态与运维告警承载。不要在通知、日志或截图中粘贴 exchange secret、Telegram token 或
Runtime credential。
