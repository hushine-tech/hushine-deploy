# RuntimeChannel、Income 与 Worker 生命周期

最后核验：2026-08-28。

## control-panel 短暂重启

runtime-agent 第一次建立连接时发送 `HELLO`，取得一次性 credential 绑定的
RuntimeChannel lease。已认证连接因 control-panel 短暂重启而断开时，agent 保留 Go
进程和所有 Python Worker，立即清除 readiness，但 health 继续为正常；旧 generation
中尚未完成的平台 RPC 在 2 秒内以 `Unavailable` 失败，不跨连接 replay。新
control-panel ready 后，agent 用保留的 fingerprint 发送 `RESUME`，同一 lease 原地
轮换，ready 恢复。Runtime 容器 PID、Agent PID、Worker PID/进程 generation 和
`session_id` 都不得变化。

仓库验收脚本用一次性用户、credential、Runtime、Session、唯一 market symbol 和
私有 barrier 构造真实 backtest。它只停止 control-panel，记录重启前后 heartbeat、
Indicator 与 Income cursor，并要求一个 Funding Income 只造成一次 wallet effect；还
覆盖 credential revoke 和超过 terminal grace 后拒绝 RESUME。所有等待都有界，清理
只按 harness owner label 与精确 ID 删除：

```bash
make local-start
make runtime-channel-restart-acceptance
```

证据默认保留在脚本打印的私有 `evidence_file`。预检会验证 live
`market_data_coverage_segments_interval_check` 能表达
`funding_rate interval=''`；存在旧约束时在创建 fixture 前明确失败，必须先通过
control-panel-service migration 修复 schema drift，不能由验收脚本改写共享 schema。

pending-call 证据不是 handler 侧合成值：同一 Python Worker 发起带唯一 correlation 的
`notification.Publish`，harness 的 Kafka frame barrier 只扣住对应 Produce response；
broker topic、barrier 和 Worker caller 文件共同证明请求已执行一次、断线以 typed
`Unavailable` 返回，而且 RESUME 后用超过最大 5 秒 reconnect backoff 的 8 秒窗口同时确认
proxy Produce 与 broker event 都仍为一次。proxy 按 connection/correlation 跟踪 Kafka API
版本，并把 Sarama Metadata v7 返回的 broker 地址重写回自身，producer 不能绕过 barrier。
`scripts/runtime-channel-kafka-proxy-integration.test.sh` 用真实 IBM/sarama SyncProducer 和本地
Kafka 验证 bootstrap、Metadata、durable Produce、hold 与 release。RESUME 本身由 credential 已消费、
单行 lease 的 `issued_at` 不变/`updated_at` 前进、connection owner 轮换和无 admission
failure 的数据库事实推导。Funding 验证比较 Income 的精确 applied amount 与三项 canonical
wallet delta，并要求 durable cursor 等于同一 Income ID。

保留的 cleanup manifest 是 fail-closed 边界：目录/文件 owner 和 mode、schema、随机 owner、
所有 ID/label/path/market 派生值必须先验证，再用数据库关系确认 fixture ownership。清理仅
执行显式、依赖顺序固定的 owner-scoped 删除；诊断只保留 PID/status/exit/image 和验收 owner
label，不保留 Docker env、credential、TLS 或 private key。

普通执行要求全新或空的 `--state-dir`；目录中已有任何文件时会在 proxy、服务、SQL、API 或
Docker 变更前拒绝，并提示仅使用 `--cleanup-only`。credential 发出后，manifest 在启动容器前
持久化 provisioning key/runtime/container/root；失败清理先从可信 baseline 恢复 control-panel，
再校验仍存在的 artifact ownership。order/portfolio/control/market 清理进度逐库持久化，重复
`--cleanup-only` 可以从已提交步骤继续；缺失 artifact 视为已清理，仍存在但关系不匹配则 fail closed。

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
