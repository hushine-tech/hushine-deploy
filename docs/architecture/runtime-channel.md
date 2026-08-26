# RuntimeChannel、Income 与 Worker 生命周期

最后核验：2026-08-27。

## Income delivery

```text
core-service confirmed/calculated Income
  → control-panel ListVenueIncomeEntries (ascending income_entry_id)
  → RuntimeChannel income/{session_id}
  → Go runtime-agent retained Income batch
  → Python session worker
  → canonical wallet apply + snapshot persist
  → WorkerDataAck
  → RuntimeDataAck
```

control-panel 的 delivery cursor 只在 ACK 后推进；断线时可从零 replay。最终幂等 authority
是 canonical Futures wallet 中持久化的 `last_applied_income_entry_id`，不是 control-panel
或 Worker 内存。Worker 只应用更大的 ID，并在同一次 wallet snapshot 更新中推进 cursor。

Income 是当前唯一延迟 Runtime ACK 到 Worker durable apply 之后的数据类型。Go Agent 每个
Session 最多保留一个待确认 batch，并把它重放给同 Session 的当前 Worker generation；
旧 generation 的 ACK、连接或平台调用不能影响 replacement。

## blocked Worker independence

Funding Account stream、Income poller、去重、数据库入账和 Runtime Agent heartbeat 都在
用户 callback 之外运行。用户断点或长循环可以造成该 Session data-plane backpressure，
但不能阻塞 RuntimeChannel heartbeat、其他 Session、公用 poller 或已经确认的 Income。
平台不会因为 Worker 暂时不可用而回滚已提交钱包事实。

Hosted、Self-hosted、Bare runtime-agent/worker 都只收到 RuntimeChannel 地址、Session
token、loopback Worker IPC 和展示事实；不接收内部数据库、Kafka、账户/order 地址或
exchange credential。

## worker-only restart

内部受保护的一行 restart 命令只替换 Python Worker，Go Agent 和 RuntimeChannel 保持
存活。它先关闭旧 generation 新准入、等待在途处理、finalize Indicator tail，把旧
Session 标为 `recoverable`，再创建新 Session ID 和 replacement Worker、重新加载当前
策略并恢复 canonical wallet/cursor。finalization 或状态更新失败时不得启动 replacement。

旧 Session 的迟到 Income 仍由 `(session_id, venue_id)` 和发生时间约束，不会附着到新
Session。保留的未 ACK Income batch 只会交给精确匹配的新 generation；durable cursor
保证 replay 不产生第二次钱包效果。

## Backtest ordering 与 Indicator

Backtest 将 Funding facts、coverage checkpoint 与 Kline 合并为同一 typed timeline。排序
键先比较 market time，同一时刻 `funding` 早于 `kline`，再按 stream index/sequence 稳定
排序。Worker 先调用平台结算、应用返回 Income，再让策略看到同一时刻 Kline。开放
Futures 仓位且 coverage 明确不完整时 fail closed；Spot 不生成 Funding event。

Indicator 仍按 1024 点分块：第 1024 点 seal 当前 chunk，第 1025 点进入下一 open chunk；
normal finish 和 worker restart 都先 finalize partial tail。Indicator finalization 失败使
Session 保持可恢复状态，不得伪装为完成。
