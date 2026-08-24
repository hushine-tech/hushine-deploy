# Binance Spot USDT

最后核验：2026-08-25。

本文描述当前分支的 Binance Spot USDT 代码契约。它是实现与运维说明，
不是“已完成真实交易所发布验收”的证明。Backtest、离线、UI、过滤器、停止与
Futures 回归可以在本地重复运行；真实 Demo、浏览器同页覆盖率和交易所对账仍要
通过独立 release gate。

## 术语：asset 不是 symbol

- `BTC`、`USDT`、`BNB` 是 Binance asset code，用在钱包余额中。
- `BTCUSDT` 是交易 symbol，用在行情、规则、订单和成交中。
- `BTCUSDT -> BTC + USDT` 的拆分只允许来自 `/api/v3/exchangeInfo` metadata；
  禁止通过字符串后缀猜测。
- 钱包可以同时有 `BTC` 与 `USDT` 两行，也可以有 Binance 返回的其他非零资产；
  钱包不得创建名为 `BTCUSDT` 的资产行。
- 同一个策略可以同时声明 Spot `BTCUSDT` 和 Futures `BTCUSDT`。两者 symbol
  文本相同，但完整路由不同，wallet、order、fill、risk 和 stream 不得合并。

## 服务所有权与通信路径

```text
quant-frontend
  -> quant-handler HTTP/JWT
  -> core-service portfolio.v1 / order.v1
  -> control-panel-service Runtime management

runtime-agent
  -> RuntimeChannel :50055
  -> control-panel PlatformProxy
  -> core-service portfolio.v1 / order.v1
```

- core-service 是 Venue、credentials、Spot account/metadata/risk、order、fill、
  stop-and-close 和 reconciliation 的唯一交易真相源。
- quant-handler 只做身份、授权、DTO 与 capability 映射，不重新实现 Binance 规则。
- control-panel 只代理认证后的 RuntimeChannel platform call，不执行交易所逻辑。
- runtime-agent 和 Python worker 不接收 Binance key/secret，也不接收 DB、Kafka、
  core-service 或 order.v1 地址。
- session 只按 `runtime_id` 路由；订单按
  `(venue_id, exchange, market, symbol)` 路由。

## Binance 官方接口

Spot 当前使用：

- 签名 `GET /api/v3/account`：账户权限和 `free`/`locked` asset 余额。
- 公共 `GET /api/v3/exchangeInfo`：symbol、base/quote asset、权限集合、订单类型和过滤器。
- 签名 `GET /api/v3/myFilters` 与 `GET /api/v3/openOrders`：账户/资产限制和未完成订单事实。
- reference/average price 接口：percent-price 与 notional 等规则所需的不可变价格事实。
- Spot WebSocket API `userDataStream.subscribe.signature`：订单/成交/余额事件。
- Demo Mode 的 REST 与 WebSocket 必须属于同一环境：REST 使用
  `https://demo-api.binance.com`，WebSocket API 使用
  `wss://demo-ws-api.binance.com/ws-api/v3`。不得把 Demo credential 发往
  `ws-api.testnet.binance.vision`；Spot Testnet 与 Demo Mode 的 key 不通用。

Spot 不使用已废弃的自定义 `/api/v3/portfolio`，也不使用
`POST|PUT|DELETE /api/v3/userDataStream` listenKey。Binance USD-M Futures 仍保持
`/fapi/v1/listenKey` 与 `/ws/<listenKey>`，Spot 改动不得改变 Futures 传输。

## Metadata snapshot 与精确过滤器

Spot metadata cache 的 key 包含 endpoint、environment 和 symbol，TTL 为 5 分钟。
同一 preflight 使用同一批次的 immutable snapshot；缓存过期且刷新失败时 fail closed，
不会继续返回过期规则。

所有 Binance 数字先保留 decimal string，再用精确十进制计算。当前过滤器覆盖包括：

- PRICE_FILTER / PERCENT_PRICE / PERCENT_PRICE_BY_SIDE
- LOT_SIZE / MARKET_LOT_SIZE
- MIN_NOTIONAL / NOTIONAL
- ICEBERG_PARTS
- MAX_NUM_ORDERS / MAX_NUM_ALGO_ORDERS / MAX_NUM_ICEBERG_ORDERS
- MAX_NUM_ORDER_AMENDS / MAX_NUM_ORDER_LISTS
- MAX_POSITION / EXCHANGE_MAX_NUM_ORDERS / MAX_ASSET
- symbol status、Spot permission set、account `canTrade`、订单类型与 USDT quote

未知或无法安全解释的交易规则会 fail closed。Backtest、Hosted、strategy-library 与
debugger 共享同一份机器生成 golden vectors；任何实现不得通过网络动态补规则。

## 下单、成交与钱包

用户策略声明 `INPUTS` 和 `ORDER_TARGETS`，订单 side 统一为 `BUY` / `SELL`。
Spot 目前只接受 Binance 且 `quoteAsset=USDT` 的 order target。

一次 Spot 下单依次经过：

1. 用户、Portfolio、Venue、Strategy、Session 与 runtime route 校验。
2. capability 与 Live rollout guard。
3. account、metadata、account filters、open orders 和 reference price snapshot。
4. 精确 tick/step/notional/position/asset admission。
5. core-service 创建 intent/attempt，再调用 Binance。
6. 以真实 order/trade identity 持久化 order、fill、commission 和 lifecycle event。
7. worker 只按已确认的 order update/fill 更新本地钱包。
8. exchange snapshot 与本地投影不一致时进入 repair/reconciliation；未修复前 route
   保持受阻，并可把 Session 标记为 `recoverable`。

commission 保留 amount 与 asset。重复 trade 通过完整 route、exchange order ID 和
exchange trade ID 幂等；不能只用 symbol 或本地 order ID 去重。

## Stop 行为

### Stop-only

只停止策略/session，不创建任何平仓订单。

### Stop-and-close

只处理该策略已声明的 Spot `ORDER_TARGETS`。core-service 先对全部目标完成 fenced
preplan，再发送第一张订单：

- 每个 symbol 通过 metadata 找到 base asset。
- 对每个 base asset 计划卖出当前完整 `free` 数量，不是策略估算仓位。
- 任一目标存在 open order、非零 locked balance、无规则/价格、无可执行数量或
  unavoidable dust，整批在第一张订单前失败。
- 成功路径逐个发送 `SELL MARKET reduce_only`，必须收到数量完全匹配的 `FILLED`；
  最后重读 authoritative account snapshot，确认没有 residual balance。
- 发送后的 timeout/进程重启/lease 过期通过 durable close operation、target lease、
  attempt resolver 与 reconciliation 恢复，避免重复 SELL。
- 中途交易所失败时 Session 为 `stop_failed`，并保留 repair/reconciliation 证据；
  不能伪装为 `stopped`。

## 支持矩阵

| 能力 | 当前实现 | 发布状态 |
|---|---|---|
| Backtest Spot USDT | Hosted worker、精确过滤器、Spot wallet、混合/多流 | 受 `backtest_spot_usdt` 控制 |
| Demo Spot USDT | 官方 REST/WS、真实 order/fill/account reconciliation | 受 `demo_spot_usdt` 控制，仍需真实 Demo gate |
| Offline Spot USDT | package v2、多输入、多 interval、Spot/Futures 混合路由 | 受 `offline_spot_usdt` 控制 |
| UI | asset wallet、route-aware run/stop/order history、结构化错误 | 只展示 effective capability |
| Live Spot USDT | 代码路径保持 fail closed | 即使配置为 true 仍返回 `SPOT_LIVE_ROLLOUT_GUARD` |
| Binance Futures | 原有路径保留 | 每次 Spot 验收必须跑 Futures 回归 |
| OKX execution | fail closed | 不在本次范围 |

四个 capability 配置值和 effective 值默认都为 `false`。关闭某个非 Live capability
后，不再接收新 session/order；已经运行的 session 仍可走 close/reconcile drain，
不能因为回滚开关而失去安全退出能力。

## Demo credential 边界

Demo Venue 只允许由受信任的 provisioning helper 经 quant-handler/core-service 创建，
key/secret 在 Venue 边界加密保存。真实验收脚本只接收公开 `VENUE_ID`。

- credential 不放入环境变量、argv、临时明文文件、日志、截图或证据 JSON。
- observer 只通过一次性 inherited anonymous FD 读取 credential，读取后立即关闭。
- Runtime 容器环境必须显式检查不存在任何 Binance key/secret。
- exchange evidence 只保留脱敏的 endpoint path/status、order/trade/account decimal
  字段和 canonical payload hash。

## 本地验证

```bash
cd hushine-deploy
bash scripts/smoke_spot_demo.test.sh
bash scripts/verify_spot_usdt.test.sh
bash scripts/acceptance/observe_spot_demo.test.sh
./scripts/verify_spot_usdt.sh all-local
```

`all-local` 固定运行 backtest、offline、UI、filters、stop 和 Futures，明确不运行
外部 Demo。`release` 会先运行 `all-local`，再要求 absolute coverage root、run-owned
Demo Venue 和 observer evidence；缺任何前置条件都以稳定 blocked reason 非零退出。

## 部署

从空数据库按 core-service → control-panel-service → instrumented Runtime image →
quant-handler → quant-frontend 启动。先保持四个 capability 关闭，完成每层 smoke 后
再分别开启 Backtest、Demo、offline；Live 不开启。

当前 baseline 不提供旧数据库升级或 schema 回滚。开发/测试环境需要换用当前 schema
时重建数据库；需要保留的数据必须先导出并走独立、显式的数据迁移流程。

## 诊断

至少同时记录：`user_id`、`portfolio_id`、`venue_id`、`strategy_id`、`session_id`、
`runtime_id`、`intent_id`、`attempt_id`、`order_id`、`exchange_order_id`、
`exchange_trade_id`、`reconciliation_run_id`、`trace_id`。

常见失败优先查看结构化 code，而不是解析 message：

- account/signature/permission/schema/network：`SPOT_ACCOUNT_*`
- 过滤器与价格：`SPOT_*` filter code
- stop-and-close：`SPOT_CLOSE_*`
- capability：`SPOT_CAPABILITY_DISABLED` / `SPOT_CAPABILITY_DRAIN_ONLY`
- Live：`SPOT_LIVE_ROLLOUT_GUARD`

所有错误、日志、gRPC details 和验收证据都必须经过 credential redaction。
