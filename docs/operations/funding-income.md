# Funding Income 运维

最后核验：2026-08-27。

## 支持矩阵

| 环境 | Spot | Futures Binance | Futures OKX |
|---|---|---|---|
| Backtest | 不产生 Funding | 历史精确事实 + 平台结算 | capability 缺失时 fail closed |
| Demo | 不产生 Funding | Account Update 触发 + Income History 确认 | fail closed |
| Live | 不产生 Funding | 代码路径存在，但 rollout guard 仍生效 | fail closed |

当前只支持 USDT 线性 Futures Funding。交易所 actual amount 是 Demo/Live 钱包入账权威；
Backtest 使用 Adapter 计算结果。OKX 未实现所需 capability 前不能绕过 preflight。

## 同步与 grace

平台 Funding poller 不在用户 Worker 中运行。调度为：

- Session 启动、stream reconnect 或 Funding Account Update：立即查询；
- pending 未确认：`10s → 30s → 1m → 2m → 5m`，之后保持 5 分钟；
- 交易所提供下次真实 Funding 时间时：在该时间后 10 秒查询；
- 健康修复：每 15 分钟加最多 1 分钟 bounded jitter；
- 每次从持久化 watermark 前 24 小时重叠读取，并分页到结尾；
- terminal Session 在 pending 全部确认且完成最终重叠查询后关闭；未解决 pending 的硬
  grace 为 Session 完成后 24 小时，超时必须告警并停止自动猜测。

查询使用进程级 weighted limiter；retryable 与 terminal adapter error 分开处理。不能用
固定时间间隔推导下一次 Funding，必须使用交易所观察到的真实时间；未知时保留 unknown。

## 状态、指标与告警

`venue_income_entries.status` 的当前语义：

- `pending_actual`：已知逻辑 settlement，但实际账单尚未确认，不更新钱包；
- `confirmed`：Demo/Live actual 已确认并首次原子应用；
- `calculated`：Backtest 精确计算并首次原子应用。

运维面至少监控：各状态行数、最老 pending age、24 小时 grace 超时数、非零
`reconciliation_delta`、retryable/terminal poll error、Income delivery cursor lag、Worker
ACK/backpressure 和 Spot Funding 行数（必须为零）。当前实现把 Funding poll/account
handling 告警写入 core-service 结构化日志；尚无独立 Funding metrics exporter，dashboard
需从这些日志与 current Income 状态派生，不能把“没有专用指标”解释为健康。

必须告警的条件包括：terminal credential/schema/decimal 错误、24 小时仍 unresolved、
actual/calculated 不一致、外部账户变化、钱包与 Income 同时不可用，以及 Runtime delivery
长期无 ACK。日志只保留 route/session/entry 等业务 ID，不记录 secret、签名 query 或完整
credential。

## Mock Binance

本地回归使用仓库内同一个 Mock Binance scenario surface，不另建 Funding mock：

```bash
cd ../core-service
go test ./internal/exchange/binance/mockserver ./internal/exchange/binance \
  ./internal/order/executor -run 'Funding|Income|GTC|IOC|FOK|GTX|Liquidation|ADL|Spot'
go test -tags=integration ./tests/integration -run 'FundingIncome|OrderModes'
```

矩阵必须包含 push-only、REST-only、延迟/重复、分页、reconnect、429、5xx、BTC/ETH/ZEC、
ONE_WAY/HEDGE、Cross/Isolated、GTC/IOC/FOK/GTX、liquidation/ADL，以及 Spot 零 Funding。

## 受保护的真实 Demo gate

真实 Binance Demo smoke 只允许通过受跟踪的
`scripts/funding-income-demo-smoke.sh` 运行。若当前 checkout 尚无该 gate，发布状态就是
blocked；不得用临时 curl、直接数据库修改或 Live credential 代替。gate 必须拒绝 Live，
只从进程环境读取 `BINANCE_DEMO_API_KEY`、`BINANCE_DEMO_API_SECRET`、
`FUNDING_SMOKE_VENUE_ID`、`FUNDING_SMOKE_SESSION_ID`，限制查询时间窗，并只输出脱敏摘要。

不要把 credential 写入文件、shell history、argv、日志、截图或 coverage。没有成功的真实
Demo 证据时，只能声明 Mock/service-chain confidence，不能声明 exchange-backed confidence。
