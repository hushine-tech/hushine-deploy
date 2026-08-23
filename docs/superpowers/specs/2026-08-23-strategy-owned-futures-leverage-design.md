# 策略主导的 Futures 杠杆配置设计

日期：2026-08-23

状态：设计已在对话中批准；本文档完成书面化后等待实施前最终复核

## 1. 背景

当前 Demo/Live Futures Session 的杠杆由启动页面输入，经 `RunStrategyRequest.leverage`
传到 strategy-service，再由 core-service preflight 查询并修改 Binance 的逐 symbol 杠杆。
这一实现存在四个问题：

1. 策略的仓位计算可能依赖固定杠杆，但页面可以提交另一个值，形成两份互相冲突的风险配置。
2. Demo 启动预览每 15 秒执行一次 preflight，而当前 preflight 会修改 Binance；用户仅打开窗口就可能
   改变交易所账户配置。
3. 一个策略可声明多个 Futures `ORDER_TARGETS`，Binance 杠杆又按 symbol 配置，单一 Session
   `leverage` 无法表达 BTC、ETH、ZEC 使用不同杠杆。
4. Binance Demo 的 `/fapi/v1/symbolConfig` 实际可返回 `marginType=CROSSED`，平台把它原样传给
   策略后与 canonical `cross` 比较，产生“必须配置 Cross”的误报。

本设计将杠杆的唯一意图来源迁移到用户策略：页面只展示，后端负责解析、验证、预览、设置、回读确认
和持久化。策略未声明时默认 `1x`。任何 Futures worker 只能在所有目标 symbol 的杠杆均确认成功后
启动。

## 2. 已批准的产品语义

- Start Demo、Backtest 和 Resume 页面不再提供杠杆输入框。
- Futures 杠杆优先级固定为：
  1. `ORDER_TARGETS[].leverage`；
  2. `MyStrategy.LEVERAGE`；
  3. 平台默认 `1x`。
- `MyStrategy.LEVERAGE` 只作用于未单独覆盖的 Futures target。
- Spot 不使用杠杆；Spot target 声明 `leverage` 是策略验证错误。
- 启动预览只读取 Binance，不修改任何交易所配置。
- 用户点击 `Start Session` 后才允许设置 Binance 杠杆。
- Binance 杠杆是逐 symbol 配置，不是整个 Venue 的单一配置；系统只处理策略声明的 Futures
  `ORDER_TARGETS`。
- 启动时对每个 target 执行“读取、必要时设置、回读确认”；全部成功后才能创建可运行 Session 并
  启动 worker。
- 设置过程中部分失败时不启动 Session，并尽力把本次已经修改的 symbol 回滚到修改前值。
- Session 成功启动后，结束时不自动恢复原杠杆；未平仓仓位可能仍依赖该配置。
- 每个 Session 按 symbol 保存生效杠杆、来源、修改前值和确认时间。
- Binance 外部枚举在 adapter 边界转换为 canonical 值，`CROSSED` 与 `cross` 均输出 `cross`，
  `ISOLATED` 输出 `isolated`。

## 3. 策略声明契约

### 3.1 示例

```python
class MyStrategy:
    LEVERAGE = 5

    ORDER_TARGETS = [
        {
            "exchange": Exchange.BINANCE,
            "market": Market.PERPETUAL_FUTURES,
            "symbol": "BTCUSDT",
        },
        {
            "exchange": Exchange.BINANCE,
            "market": Market.PERPETUAL_FUTURES,
            "symbol": "ETHUSDT",
            "leverage": 10,
        },
        {
            "exchange": Exchange.BINANCE,
            "market": Market.PERPETUAL_FUTURES,
            "symbol": "ZECUSDT",
        },
    ]
```

有效结果为：

| Symbol | 有效杠杆 | 来源 |
|---|---:|---|
| BTCUSDT | 5x | `strategy_default` |
| ETHUSDT | 10x | `order_target` |
| ZECUSDT | 5x | `strategy_default` |

如果删除 `LEVERAGE` 且 target 也未声明 `leverage`，有效值为 `1x`，来源为
`platform_default`。

### 3.2 验证规则

- `LEVERAGE` 和 `ORDER_TARGETS[].leverage` 必须是 Python 字面量正整数。
- 布尔值、零、负数、小数、字符串、动态表达式和非有限数字均拒绝。
- target 级值只允许出现在 Futures target。
- 只有 Spot target 且声明了全局 `LEVERAGE` 时，拒绝无效的全局配置，避免策略作者误以为 Spot
  会应用杠杆。
- Spot/Futures 混合策略可以声明全局 `LEVERAGE`；它仅作用于 Futures targets。
- validator 为每个 target 计算并返回 `effective_leverage` 与 `leverage_source`。后续组件不得重新
  实现优先级算法。
- 交易所对具体 symbol 支持的杠杆范围属于 preflight 事实，不由静态 Python validator 猜测。

## 4. 权威边界与数据流

```text
strategy source
  -> strategy-service validator
       -> declared ORDER_TARGETS + effective leverage/source
       -> preview: core-service read-only futures configuration query
       -> start:   core-service apply-and-confirm transaction
       -> confirmed per-symbol facts
       -> session persistence
       -> RuntimeChannel bootstrap
       -> Python worker / canonical wallet
```

### 4.1 strategy-service

strategy-service 是策略声明及有效杠杆计算的唯一权威：

- `ValidateStrategySource` 返回逐 target 杠杆事实；
- `PreviewRunStrategy` 使用相同解析结果构造只读预览；
- `RunStrategy` 在真正启动时重新加载并重新验证策略，不能复用可能过期的前端解析结果；
- 策略源在 preview 与 start 之间变化时，以 start 重新解析的结果为准；
- 旧客户端提交的全局 request leverage 不得覆盖策略声明。

### 4.2 core-service

core-service 持有 Venue credential、Binance adapter 和交易所配置真相，负责：

- 按明确的 `(venue_id, exchange, environment, market, symbol)` 查询当前杠杆；
- 在 read-only preview 中返回当前值和是否需要修改；
- 在 start apply 阶段设置并回读确认；
- 执行并发 admission、失败回滚和持久化；
- 向 worker 提供已经确认的 canonical wallet/risk metadata；
- 对 Binance `CROSSED` 等外部枚举执行边界规范化。

Runtime、worker、quant-handler 和前端均不得持有 Binance credential 或直接设置杠杆。

### 4.3 quant-handler 与 control-panel-service

- quant-handler 只做身份授权和字段映射，不解析 Python，也不计算杠杆优先级。
- control-panel-service 继续负责 runtime/session 控制和 RuntimeChannel 转发，不访问 Binance。
- start 路径必须在 worker launch 之前得到 core-service 的完整确认结果。

## 5. Preview 与 Start 分离

### 5.1 Preview

预览必须是严格只读操作。对每个 Futures target 返回：

- venue、exchange、market、symbol；
- `effective_leverage`；
- `leverage_source`；
- Binance `current_leverage`；
- `change_required`；
- 查询状态和结构化错误。

预览可以按现有频率刷新，但不得调用 Binance leverage POST endpoint，也不得写 Session 杠杆事实。
查询失败时 Start 按钮保持不可用，并显示具体 target 和可重试性。

### 5.2 Start

用户点击 Start 后，服务端重新执行：

1. 读取当前策略源并计算逐 target 有效杠杆；
2. 解析并确认目标 Venue；
3. 获取 target 级配置 admission；
4. 重新读取 Binance 当前杠杆；
5. 只对不一致的 symbol 发送设置请求；
6. 对所有 symbol 回读并确认等于目标值；
7. 原子保存 Session 的已确认 target facts；
8. 创建/推进 Session，并向 runtime-agent 发送启动命令。

页面预览结果只是告知用户，不能成为 Start 的授权事实或跳过服务端重检。

### 5.3 Backtest 与离线调试

- Backtest 和 strategy-debugger-cli 不访问或修改 Binance。
- 它们使用相同的策略声明解析和有效杠杆算法初始化模拟 Futures wallet/risk metadata。
- 不声明时同样为 `1x`，保证 Backtest、Demo 与本地调试的仓位计算一致。

## 6. 失败、回滚与并发

### 6.1 Apply journal

启动配置按稳定的 route/symbol 排序执行。每个 target 在修改前记录：

- 原始杠杆；
- 目标杠杆；
- 是否发出了修改请求；
- 修改响应；
- 回读确认结果。

只要任意 target 查询、设置或确认失败，Session 不得进入 running，worker 不得启动。

### 6.2 Best-effort rollback

部分 target 已修改、后续 target 失败时，按修改顺序的逆序把本次已修改 target 恢复为原始杠杆，并逐个
回读确认。返回结果必须同时包含原始启动错误和每个 rollback 状态。

回滚失败时：

- 返回稳定错误码 `LEVERAGE_ROLLBACK_FAILED`；
- 在页面标出仍处于目标值或未知值的 symbol；
- 发布系统通知事件；
- 不伪装为“启动失败且账户未变化”。

### 6.3 Active target admission

同一 Binance 账户的同一 Futures symbol 不能同时被两个活跃 Session 声明为 order target。
admission 键固定为
`(exchange, environment, credential_fingerprint, market, symbol)`，因此重复使用同一 credential
创建的多个 Venue 也不能绕过冲突检查。preview 不获取 admission；用户点击 Start 后获取，持有到
Session 终止，覆盖 apply、worker launch 和运行期的完整竞态窗口。

Session 终止、启动失败且回滚完成、或明确恢复流程结束后释放 admission。过期 lease 的恢复必须与
现有 Session 状态核对，不能仅依靠本地内存。

## 7. 协议与持久化

### 7.1 协议演进

策略声明及预览中的 target binding 增加：

- `effective_leverage`；
- `leverage_source`；
- preview 专用的 `current_leverage` 与 `change_required`；
- start/apply 结果中的确认值与错误/回滚信息。

现有 `RunStrategyRequest.leverage`、`PreviewRunStrategyRequest.leverage` 和相关 HTTP 字段保留为 wire
兼容字段并标记 deprecated，但新服务忽略其非零值。不能让旧客户端继续改变权威配置。

协议字段的最终删除不在本轮范围内；删除需要单独的兼容性决定和跨仓库 rollout。

### 7.2 Session target facts

新增逐 target 的 Session 风险事实存储，逻辑字段至少包含：

```text
session_id
venue_id
exchange
environment
market
symbol
effective_leverage
leverage_source
previous_leverage
confirmed_leverage
confirmed_at
created_at
```

主键/唯一键覆盖 `(session_id, venue_id, market, symbol)`。只有 start apply 全部成功后，事实才作为
Session bootstrap 的权威输入写入。

Start 在创建 Session 之前生成独立 `launch_operation_id`。apply journal、admission holder 和 rollback
结果均按该 operation 记录，不依赖尚未存在的 Session 外键。全部 target 确认成功后，在一个数据库
事务中插入 `strategy_sessions`、逐 target Session facts，并把 admission holder 从 operation 转交给
`session_id`；事务提交后才允许发送 worker start 命令。失败 operation 保留审计和 rollback 结果，
但不能产生可运行 Session 或“已确认 Session facts”。

现有 `strategy_sessions.leverage` 保留为历史兼容字段：

- 历史 Session 没有 target facts 时，读路径继续展示该值；
- 新 Session 的业务和 worker 不读取它；
- mixed-leverage Session 不得用这个单值伪装全部 targets；
- 后续删除该列需要独立迁移与兼容决策。

数据库 migration 必须同时通过空库一次性部署和现有数据库增量升级。`db/README.md`、基线 SQL 与
service migrations 必须保持一致。

## 8. Runtime 与策略执行

- Runtime bootstrap 携带已确认的逐 target 杠杆事实或可从 canonical snapshot 无损获得同一事实。
- worker 启动时验证声明的有效杠杆与 bootstrap risk metadata 一致；不一致 fail closed，不能仅告警
  后继续运行。
- 策略仓位计算使用 target 的已确认杠杆。
- 策略不再自行调用交易所配置 API，也不重复实现 `CROSSED` 等外部枚举兼容。
- Resume/调试重启加载新策略代码后产生新 Session，并重新执行 preview/start 语义；旧 Session 的
  target facts 不可直接复用于已修改代码。
- 当前 BTC/ETH/ZEC 测试策略改用标准 `LEVERAGE = 10` 声明。其仓位计算使用 canonical metadata，
  删除 `REQUIRED_LEVERAGE` 与重复告警分支。

## 9. 页面设计

删除 Start Demo、Backtest 和 Resume 中的 Leverage 输入。启动窗口在订单目标区域展示：

```text
BTCUSDT  5x   Strategy default   Current: 3x   Will change on start
ETHUSDT 10x   Target override    Current: 10x  No change
ZECUSDT  5x   Strategy default   Current: 2x   Will change on start
```

页面要求：

- Spot target 不显示杠杆；
- 所有 Futures target 相同也仍保留逐 symbol 事实，可额外显示摘要；
- 显示来源，避免用户误以为值来自页面或 Venue；
- 用户点击 `Start Session` 即确认列表中的交易所修改，不增加额外 checkbox；
- apply 期间禁用重复提交并显示逐 target 进度；
- 失败时展示设置和 rollback 的真实结果；
- Session 详情优先读取 target facts，历史数据才回退旧全局值。

## 10. Canonical Binance 转换

Binance adapter 增加集中式 margin-mode 规范化：

```text
CROSSED / crossed / cross -> cross
ISOLATED / isolated       -> isolated
```

该转换同时用于：

- `/fapi/v1/symbolConfig` risk metadata；
- `/fapi/v3/positionRisk` position fields；
- 提供给 wallet、strategy 和页面的 canonical snapshot。

未知值保留为非 canonical/unsupported 并 fail closed，不能猜成 cross。策略只比较 canonical 值。

## 11. 兼容与发布顺序

采用 additive-first rollout：

1. 扩展 proto/HTTP response 和数据库；旧 request 字段继续存在。
2. strategy-service 解析并返回逐 target 杠杆，core-service 支持 read-only preview 和 apply。
3. Runtime bootstrap/worker 消费逐 target facts。
4. 前端切换为只展示并停止提交 leverage。
5. 所有消费者升级后，旧 request 字段仅保留 deprecated/ignored 状态。

服务版本不一致时 fail closed：如果策略声明包含非默认或 mixed leverage，而下游不支持逐 target facts，
预检必须返回 capability/version 错误，不能退化为旧全局字段。

## 12. 测试与验收

### 12.1 策略声明

- 未声明时 Futures 默认为 `1x`；
- 全局 `LEVERAGE` 应用于所有未覆盖 Futures targets；
- target override 优先；
- 多 symbol 产生 5x/10x/5x 等 mixed facts；
- 非正整数、动态表达式、Spot leverage 被拒绝；
- Spot/Futures 混合策略只对 Futures 应用全局值。

### 12.2 Preview 与 apply

- preview 只调用 GET，不调用设置 endpoint；重复刷新也不修改账户；
- start 对相同值不发送 POST；
- start 对不同值设置并回读确认；
- 任意查询/设置/回读失败不启动 worker；
- 三 target 中第二或第三个失败时，已修改 targets 逆序回滚；
- 回滚失败返回结构化结果并发布系统通知；
- 并发启动同一 Venue/symbol 被 admission 拒绝。

### 12.3 持久化与 Runtime

- 新 Session 保存完整 target facts；
- mixed leverage 不读取旧全局列；
- 历史 Session 页面仍可回退旧字段；
- bootstrap 与策略声明不一致时 worker fail closed；
- Resume 新代码重新解析、配置和持久化；
- Backtest、Demo 和 debugger 使用相同有效杠杆计算。

### 12.4 页面与真实 Demo smoke

- 页面没有可编辑 leverage 字段；
- preview 显示 symbol、目标、来源、当前值和是否修改；
- 点击 Start 前 Binance 状态不变；
- 点击 Start 后 Binance 三个目标变为策略声明值；
- Session facts、worker wallet metadata 和 Binance 回读一致；
- BTC/ETH/ZEC 的订单数量按各自有效杠杆和 wallet balance 计算；
- `CROSSED` 不再产生 Cross 误报；真实非 Cross 配置仍 fail closed。

真实 Demo 测试使用覆盖率插桩环境，但不得在日志或报告中暴露 API key、secret、Telegram token 或
credential payload。

## 13. 非目标

- 不支持 Spot margin、借贷或杠杆代币。
- 不允许策略在运行中动态改变 leverage；修改策略后通过新 Session/Resume 流程生效。
- 不在 Session 成功结束时自动恢复 Binance 杠杆。
- 不删除旧协议字段或 `strategy_sessions.leverage` 列。
- 不改变保证金模式、持仓模式或订单路由的既有权威边界。
- 不让 self-hosted/bare runtime 获得内部服务地址或 Binance credential。

## 14. 完成标准

只有同时满足以下条件才可声称完成：

1. 所有仓库的协议生成物一致；
2. 空库和增量数据库部署测试通过；
3. strategy-service、core-service、control-panel-service、quant-handler、quant-frontend、runtime 和
   debugger 的相关单元/集成测试通过；
4. Go tests/vet、Python pytest、前端 build 与 tracked script tests 通过；
5. Preview 被证明为无副作用；
6. 真实 Binance Demo 多 symbol smoke 证明设置、回读、Session facts、下单 sizing 一致；
7. 覆盖率报告可生成，且没有敏感信息泄漏；
8. 当前运维、代码逻辑和用户手册文档更新为策略主导语义。
