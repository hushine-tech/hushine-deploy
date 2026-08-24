# 策略主导的 Futures 杠杆

最后核验：2026-08-25。

## 用户声明

杠杆只来自策略源码，优先级固定为：

1. `ORDER_TARGETS[]` 当前 target 的 `leverage`
2. Strategy class 的 `LEVERAGE`
3. 平台默认 `1x`

值必须是正整数。Spot target 不能声明 `leverage`，Spot-only Strategy 不能声明
class-level `LEVERAGE`。Demo、Backtest 和 Resume 页面没有杠杆输入；Start 请求也不
携带杠杆权威值。

```python
class MyStrategy(Strategy):
    LEVERAGE = 5
    ORDER_TARGETS = [
        {
            "exchange": "binance",
            "market": "perpetual_futures",
            "symbol": "BTCUSDT",
            "leverage": 3,
        },
        {
            "exchange": "binance",
            "market": "perpetual_futures",
            "symbol": "ETHUSDT",
        },
    ]
```

上例中 BTC 使用 `3x`，ETH 使用 class-level `5x`。同一 Strategy 可以为 BTC、ETH、
ZEC 等多个 target 声明不同值。

## Preview

Preview 通过所选 `runtime_id` 创建一次性 worker，解析当前 active Strategy，计算每个
target 的有效杠杆和来源，并经 RuntimeChannel 请求 core-service 读取 Binance 当前
配置。Preview 是只读操作：

- 不调用 Binance 设置接口
- 不获取 target admission
- 不创建 launch journal、Session、target facts 或 notification outbox
- worker 返回后即销毁

页面应展示每个 symbol 将使用的倍数、来源以及当前交易所读值。读取失败时明确阻止
Start，不能猜测为 `1x`。

## Start 的原子边界

Start 使用 preparation worker 和正式 session worker 两个阶段：

1. runtime-agent 创建新的 `session_id` 和 `launch_operation_id`。
2. preparation worker 重新读取 active Strategy，返回 source digest、INPUTS、
   ORDER_TARGETS、逐 target 有效杠杆/来源、Venue 路由和风险事实；不执行用户 callback。
3. agent 通过 RuntimeChannel 提交 typed manifest。control-panel 使用已认证的 user 和
   runtime 身份覆盖路由事实，只做校验和代理，不解析 Python。
4. core-service 按
   `(exchange, environment, credential_fingerprint, market, symbol)` 获取唯一 admission，
   并按稳定的 route/symbol 顺序执行 read → 必要时 set → readback。
5. 每次可能改变 Binance 前先持久化 rollback obligation。全部 target 确认后，
   core-service 在一个数据库 transaction 中创建 `pending` Session、逐 target facts，
   转交 admission holder 并提交 launch operation。
6. agent 读回已提交绑定，构造 typed bootstrap，之后才创建正式 worker。
7. 正式 worker 再次解析当前源码，核对 source digest、target 集合、有效杠杆/来源、
   confirmed leverage、Venue/environment 和 wallet metadata；任何不一致都 fail closed。

因此 worker 开始运行时，每个 Futures target 都已有不可歧义的 committed fact；Session
不会从一个全局标量推断多币种杠杆。

## 环境语义

- `environment=0` Backtest：使用相同 resolver 和模拟 wallet metadata，不调用 Binance，
  不占用 live admission。
- `environment=1` Demo：Preview 只读；用户确认 Start 后才允许设置并 readback Binance。
- `environment=2` Live：仍受 rollout guard 保护。
- strategy-debugger-cli：使用相同 resolver 和模拟 Futures wallet，不提供额外 override。

Hosted、Self-hosted 和 Bare worker 都只通过 RuntimeChannel 访问平台；不会收到 Binance
credential、数据库、Kafka、core/order 或 notification endpoint。

## 失败与回滚

若 read、set 或 readback 任一步失败，core-service 对本次可能改变的 target 按逆序
rollback 并再次 readback：

- 全部恢复确认：不创建可运行 Session，释放 operation admission。
- 无法确认恢复：返回 `LEVERAGE_ROLLBACK_FAILED`，launch operation 和 admission 保持
  `recovery_required`，阻止同一 credential/symbol 被新启动绕过。
- recovery 事件按 `launch_operation_id` 写入 durable notification outbox 并去重；
  Telegram 发送失败不会丢掉待处理事实。

成功 Session 终止时释放 admission，但不会自动把 Binance 杠杆恢复为 Start 前的值。

## Resume

Resume 总是创建新的 Session，并显式携带 `resume_session_id`。core-service 在同一个
transaction 内校验来源 Session 的 user、Portfolio、environment、Strategy 和状态，
将可恢复来源标记为 `stopped` 并释放旧 admission，再为新 launch 获取 admission。
任一新 target 冲突会回滚整笔操作，旧 Session 保持 `recoverable`。

新 Session 重新读取当前源码、重新执行 leverage apply/readback 并写入自己的逐 target
facts；旧 Session 只作为审计历史，不会改回 `running`。

## 持久化与检查

当前 `portfolio` baseline 一次性创建：

- `strategy_launch_operations`
- `strategy_leverage_apply_attempts`
- `strategy_target_admissions`
- `strategy_session_target_facts`
- `strategy_leverage_notification_outbox`

关键验证：

```bash
cd core-service
go test ./internal/service ./internal/repository ./internal/exchange/binance -count=1
go test ./internal/notification -count=1
```

页面和 API 读取 Session 杠杆时必须展示 `strategy_session_target_facts` 的逐 target 结果，
Spot Session 返回空的 Futures facts。
