# Backtest Position Contract、Funding 历史链路与 Runtime 恢复设计

日期：2026-08-28

状态：设计已批准；进入实施

## 1. 背景

`docs/bug-reports/2026-08-28-backtest-funding-venue-gaps.md` 暴露出四类相关问题：

1. Venue 钱包初始化在服务边界上同时使用 `direction`、字符串 `position_side` 和整数
   `position_side`，同一个持仓方向没有唯一契约。strategy-service 因字段不一致可能把已有持仓读成
   空持仓。
2. Historical Futures Backtest 会申请 Funding 历史数据，但 control-panel-service 的创建入口仍按
   Live Kline 规则验证所有请求，导致 Funding 请求在进入 scraper 前被拒绝。
3. Funding 完整性检查采用 fail-closed 语义；当持仓已经存在而历史 Funding 不完整时，Session 会立即
   失败。这个保护本身正确，但当前缺失链路把正常回测也变成失败。
4. runtime-agent 只建立一次 RuntimeChannel。control-panel-service 重启或连接短暂中断时，agent 会停止
   worker 并退出，虽然服务端已经实现 `RESUME` 和 resume token 轮换。

此外，订单在写入订单表之前发生的参数、路由或配置错误，当前可能只留在 runtime 日志中。用户在页面上
看到 Session 有行情但没有订单，也看不到可操作的错误原因。

本设计修复上述根因，并把跨服务契约集中到一处。系统尚未上线，因此采用硬切换，不增加旧字段别名、
双写、回退读取或历史协议兼容层。

## 2. 目标与非目标

### 2.1 目标

- 为所有 Futures 持仓与订单定义唯一、强类型的 `FuturesPositionSide` 契约。
- 让 Historical Futures 请求能按需拉取 Kline 和 Funding，Live 仍然只接受 Kline。
- 保留 Funding 数据不完整时立即 fail closed 的安全语义。
- 让订单持久化前的失败对 Session 和页面可见，并禁止不安全的自动重放。
- control-panel-service 重启时，runtime-agent 和现有 worker 不退出，连接恢复后继续工作。
- 在 One-way/Hedge、Cross/Isolated 组合下验证持仓、Funding 与钱包结果；`Hedge + Isolated` 是强制
  验收场景。
- 干净数据库必须通过一次部署完成建表并可用。

### 2.2 非目标

- 不实现 RuntimeChannel v2、HA connection epoch 或跨 control-panel 实例迁移。
- 不改变“杠杆由策略声明，未声明时为 1x”的产品语义。
- 不修改 scraper 的静态 Live collector 开关来承载历史 Funding。
- 不恢复或继续维护 strategy-debugger-cli。
- 不在通用层加入 Binance 专有请求、字段或计算分支。
- 不为尚未上线的旧客户端、旧数据库或旧 runtime-agent 增加兼容代码。

## 3. 唯一 Futures Position Side 契约

### 3.1 Source of Truth

唯一契约定义在：

```text
core-service/proto/portfolio_service.proto
```

定义共享枚举：

```proto
enum FuturesPositionSide {
  FUTURES_POSITION_SIDE_BOTH = 0;
  FUTURES_POSITION_SIDE_LONG = 1;
  FUTURES_POSITION_SIDE_SHORT = 2;
}
```

数值与当前订单方向语义一致。`BOTH = 0` 也是 proto3 的默认值，专门用于 One-way；Hedge 模式会通过
模式校验拒绝缺失或 `BOTH`，因此不再增加 `UNSPECIFIED` 兼容值。

所有 canonical proto 中表达 Futures 持仓腿的字段都使用该枚举，包括：

- `portfolio.v1.PositionEntry.position_side`
- `portfolio.v1.FuturesPosition.position_side`
- `portfolio.v1.FundingPositionLegFact.position_side`
- `order.v1` 中所有请求、记录、成交结果和查询响应的 `position_side`

`order_service.proto` 直接 import 并引用 `portfolio.v1.FuturesPositionSide`，不得复制第二个枚举或继续使用
裸 `int32`。

### 3.2 删除旧字段

`FuturesPosition.direction` 直接删除，并 reserve 原字段号和字段名。HTTP Venue API 只输出：

```json
{"position_side":"BOTH|LONG|SHORT"}
```

不再输出或接受 `direction`，也不接受数字、`+1/-1`、空字符串等兼容表示。数据库可以继续使用
`0/1/2` 存储，但仓储和业务代码必须通过生成的 enum 转换，不能传播魔法数字。

### 3.3 模式规则

- One-way：只允许 `BOTH`。
- Hedge：只允许分别存在的 `LONG`、`SHORT` 腿；不得先净额合并。
- Cross/Isolated 不改变 position side，只决定保证金归属和风险计算方式。
- 空仓钱包不需要伪造持仓腿。
- 用户策略仍可写可读字符串 `BOTH`、`LONG`、`SHORT`；strategy-service 在策略边界严格规范化为共享
  enum。内部如需 `direction_key`，只能从共享 enum 派生，不能跨服务传递。
- Binance adapter/registry 负责把 enum 转成 Binance `positionSide` 字符串；core-service 通用逻辑不能
  知道 Binance 字段。

### 3.4 杠杆边界

杠杆继续由策略中的每个 Order Target 声明，未声明时为 `1x`。Session 启动检查按策略配置账户并告知
用户实际杠杆。Venue 钱包初始化和 position-side 契约不引入 Venue 级杠杆默认值，也不恢复页面上的
Session 杠杆输入框。

## 4. Historical Funding 请求链路

### 4.1 Scope-aware 验证

`CreateMarketDataRequest` 必须先规范化并验证 `scope`，再选择 key 验证器：

- `scope=live`：只允许可实时投递的 Kline，`needs_live_delivery=true`。
- `scope=historical`：允许 Kline 和 Funding；不得要求 Live delivery。
- 其他或空 scope：明确拒绝，不隐式猜测。

Historical validator 接受 Futures Funding key，但仍严格验证 exchange、market、symbol、时间范围和支持
能力。Spot 不创建 Funding companion。

### 4.2 Demand-driven，不依赖静态 collector

Historical Funding 沿现有 demand-driven 链路运行：

```text
strategy/backtest request
  -> control-panel historical market-data request
  -> scraper HistoricalRuntime
  -> exchange adapter funding history capability
  -> TimescaleDB coverage
  -> backtest funding facts
```

scraper 的静态 `forward_collector`/`reverse_collector` 只控制持续运行的 Live collector，不是历史请求的
开关，本次不修改它们。以后替换为 OKX 时，只替换 adapter capability，control-panel 与 strategy 通用
逻辑不增加交易所分支。

### 4.3 数据库基线

control-panel 当前本地数据库曾在 migration 已登记后修改基线文件，因此本地 kline-only constraint 与
源码不一致。系统尚未上线，本次不增加补丁兼容 migration：

1. 修正并验证当前 baseline schema；
2. 重建本地 control_panel 数据库；
3. 从空数据库一次执行全部 migration；
4. 验证 Kline/Funding historical request 均能插入、领取、完成和查询覆盖率。

### 4.4 Funding fail-closed 语义

只要 Futures 持仓腿已经打开，所需时间区间内 Funding coverage 不完整，Session 就立即以结构化错误
失败。它不等待下一次结算边界才发现缺失，也不使用 0 费率静默继续。修复目标是保证数据链完整，不是
放松保护。

## 5. 订单失败可见性

订单结果分为三类：

1. **已持久化的交易所拒单**：订单表已有尝试记录和明确失败状态。它属于策略可观察的订单结果，默认不
   终止 Session。
2. **持久化前的确定性拒绝**：position side、margin mode、leverage、route、symbol metadata 或权限
   校验失败。它必须成为 typed fatal Session error，例如 `ORDER_REQUEST_REJECTED`，带 symbol、
   venue、stage 和可操作原因，不能只写日志。
3. **结果未知**：请求可能到达交易所，但平台没有得到可确认结果且没有持久化事实。Session 以
   `ORDER_EXECUTION_UNKNOWN` fail closed；绝不自动重放，以免重复下单。

错误传播路径固定为：

```text
worker canonical error
  -> runtime-agent session status patch
  -> RuntimeChannel
  -> control-panel session state
  -> core Session error fields
  -> quant-handler / quant-frontend
```

页面复用现有 Session 错误展示。已有 Telegram 终止通知策略应在结构化状态写入后触发；本次不创建另一套
仅用于订单的通知协议。

## 6. RuntimeChannel 自动恢复

### 6.1 状态机

runtime-agent 从一次性 `Run` 改为连接监督器：

```text
STARTING
  -> CONNECTING
  -> HELLO + ACK
  -> READY
  -> transient disconnect
  -> RECONNECTING
  -> RESUME + ACK
  -> READY
```

首次连接发送 `HELLO`。收到 ACK 后只在内存中保存服务端返回的最新 resume fingerprint；以后重连发送
现有协议的 `RESUME`。每次 ACK 可能轮换 fingerprint，agent 必须原子替换旧值。token 不写磁盘、不输出
日志。

### 6.2 进程和 worker 生命周期

- 短暂断线不能取消 agent 根 context，不能停止 worker，也不能清除 worker/session 内存。
- `coordinateRuntimeLifecycle` 只在根 context 取消或不可恢复错误时执行现有 shutdown。
- 心跳和状态在连接恢复后继续；同一个 agent 进程、runtime identity 和 worker generation 保持不变。
- 重连期间新发起的 platform call 在本代连接未 ACK 前不可发送。

### 6.3 重试规则

监督器使用可取消、带 jitter 的有界指数退避：初始 `250ms`，上限 `5s`。测试注入可控 backoff，生产
代码不得使用不可取消的 sleep。

以下属于可恢复：连接拒绝、EOF、Unavailable、DeadlineExceeded 和短暂网络错误。以下属于不可恢复并
终止 agent：身份冲突、认证/权限错误、resume token 明确无效、协议版本或 dependency profile 不兼容。
若服务端明确拒绝 RESUME，agent 不得偷偷降级成新的 HELLO 抢占同一 runtime identity。

### 6.4 Pending call 语义

连接断开时，所有等待中的 runtime-to-platform call 立即以 `Unavailable` 结束，释放 pending map。它们
不跨连接自动重放。调用方只有在业务操作本身具有明确幂等键且显式决定重试时才可重新发起。

每一代连接有独立 readiness 信号；旧的 `close-once connected channel` 不能表示重连成功，必须替换为
可重复的连接状态/generation。发送路径必须绑定当前 READY generation，避免把 frame 写入已经失效的
stream。

## 7. 验收矩阵

### 7.1 Position mode × Margin mode

至少覆盖下面所有组合，并核对 position side、保证金、钱包、PnL 和 Funding 逐腿明细：

| Position mode | Margin mode | 合法持仓腿 | 必测结果 |
| --- | --- | --- | --- |
| One-way | Cross | BOTH | 启动、开仓、平仓、Funding、钱包一致 |
| One-way | Isolated | BOTH | isolated margin 归属正确 |
| Hedge | Cross | LONG + SHORT | 两腿独立，Funding 分别计算后汇总 |
| Hedge | Isolated | LONG + SHORT | 两腿及各自 isolated margin 独立，Funding 分别计算后汇总 |

`Hedge + Isolated` 必须同时覆盖 LONG、SHORT 两腿，不能用净持仓替代。再增加空仓、非法 One-way +
LONG/SHORT、非法 Hedge + BOTH，确认后两者在 Session 启动或第一条订单前明确失败。

多币种场景至少使用 BTCUSDT、ETHUSDT、ZECUSDT，确认不同 symbol 的 mode、margin 和 Funding 不串账。

### 7.2 Funding 历史与 Backtest

- 直接创建 Historical Funding 请求，不依赖 Kline companion。
- Historical Futures Kline 幂等创建对应 Funding companion；Spot 不创建。
- Kline 完整但 Funding 缺失时，Session 明确 fail closed。
- 缺失区间补齐后可以重新运行，且不会重复保存 Funding coverage 或 income。
- 至少三天、跨多个真实 funding settlement 的持仓，逐腿核对 rate、mark price、signed quantity、
  signed fee、钱包和最终权益。
- Hedge LONG/SHORT 分别计算再汇总；Cross/Isolated 公式一致、归属不同。

### 7.3 订单错误

- Mock Binance 返回全部成交、部分成交、GTC/IOC/FOK 拒绝和交易所业务拒绝时，已有订单记录保留并可
  查询。
- position side、margin mode、leverage 或 route 在写订单前失败时，Session 页面显示 typed fatal
  error，不能只出现“零订单”。
- 模拟请求发送后断线且结果未知，验证 `ORDER_EXECUTION_UNKNOWN`，并证明没有自动重放。
- Spot 与 Futures 分开测试；Spot 不出现 hedge、cross、isolated 或 Funding 语义。

### 7.4 Runtime 恢复

真实启动 control-panel、runtime-agent 和 worker：

1. 等待 agent READY 并启动一个持续运行的 Demo Session；
2. 记录 agent PID/container identity、worker PID/generation、session_id 和心跳；
3. 只停止并重新启动 control-panel-service；
4. 断线期间验证 agent 与 worker 仍存活，pending call 返回 `Unavailable`；
5. 恢复后验证 agent 用 RESUME 重新 READY，心跳和状态继续；
6. 验证 agent/worker identity 与 session_id 未变化，策略继续处理新数据；
7. 注入无效 token 或身份冲突，验证 fail closed 且不降级 HELLO。

### 7.5 干净部署

从空数据库启动 PostgreSQL/TimescaleDB、Kafka、ELK、Jaeger 和全部服务；一次 migration 必须完成建表。
随后创建 Historical Kline/Funding 请求、启动 Demo 和 Backtest，确认不存在手工补表或第二次 SQL 步骤。

## 8. 实施顺序

1. 先写失败测试，锁定共享 enum、字段删除和模式校验。
2. 修改 proto source of truth，重新生成 core-service Go 和 strategy-service Python/Go bindings，修复所有
   编译调用点。
3. 以测试驱动修复 scope-aware Historical Funding 请求和 baseline schema。
4. 以测试驱动补齐订单失败结构化传播。
5. 以测试驱动把 RuntimeChannel 拆成单连接 primitive 与重连监督器。
6. 运行各仓库单元、集成、契约和构建测试。
7. 重建本地数据库与镜像，完成真实 Runtime restart、Backtest Funding 和 Position/Margin 验收矩阵。
8. 更新仓库内运维、架构和用户文档，移除与新契约冲突的旧说明。

## 9. 预期影响仓库

- `core-service`：canonical proto、生成代码、钱包初始化、订单与 Funding position-side 使用点。
- `strategy-service`：生成绑定、策略边界规范化、钱包 bootstrap、runtime-agent reconnect supervisor。
- `quant-handler`：Venue JSON 映射、Session 错误映射和相关契约测试。
- `control-panel-service`：Historical key validation、RuntimeChannel 恢复/状态测试、数据库基线。
- `scraper`：Historical Funding capability 的链路验证，只有发现真实缺口才修改实现。
- `quant-frontend`：删除旧字段消费、展示 Session typed error；不恢复页面杠杆输入。
- `hushine-deploy`：设计、测试矩阵、运维和用户文档，以及本地环境重建验证。

## 10. 完成标准

只有以下条件全部满足才可宣称完成：

- 源码中 canonical Futures position side 不再同时存在 `direction`、string 和 raw int 三套表示。
- 所有生成代码与 source proto 一致，并有防漂移检查。
- Historical Funding 请求与覆盖率链路通过真实数据库验证。
- 订单持久化前失败在页面可见，结果未知的请求不会自动重放。
- control-panel 重启后原 agent、worker 和 Session 能恢复工作。
- One-way/Hedge × Cross/Isolated 全矩阵通过，特别是 `Hedge + Isolated`。
- Spot/Futures 的 GTC、IOC、FOK 和部分/全部成交 mock 场景通过。
- 空数据库一次部署可用，相关仓库测试、构建和静态检查全部通过。
