# Backtest Contract、Funding 与 Runtime Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` to execute this plan task-by-task, with specification review followed by code-quality review for every task.

**Goal:** 硬切换到唯一 Futures position-side 契约，修通 Historical Funding、订单致命错误可见性与 RuntimeChannel 重连，并用干净数据库和完整交易矩阵证明现有 Spot/Futures 功能不受影响。

**Architecture:** `core-service/proto/portfolio_service.proto` 是 position side 的唯一来源；交易所表示只存在于 adapter 边界。Historical 数据按 scope 选择校验器并由 scraper 的 demand-driven runtime 拉取。订单在“已持久化失败 / 请求前确定拒绝 / 执行结果未知”三个状态之间严格区分。runtime-agent 保持单 supervisor、单活动连接，首次 HELLO、断线后 RESUME，断线中的 platform call fail closed 且绝不重放。

**Tech Stack:** Go 1.24、Python 3.13/uv/pytest、Protocol Buffers/gRPC、React/TypeScript、Node contract tests、PostgreSQL/TimescaleDB、Kafka、Docker Compose、Mock Binance。

**Spec:** `docs/superpowers/specs/2026-08-28-backtest-contract-funding-runtime-recovery-design.md`

## Global Constraints

- 工作区根目录不是 Git 仓库；每个服务独立提交，只暂存本任务改动。
- 系统尚未上线：删除 `direction`、数字/string 双读、旧字段别名、双写和旧协议回退；不新增兼容 migration。
- 通用层禁止出现 Binance 专有字段或计算；`positionSide`、Funding REST/WS 映射仅在 Binance adapter/registry。
- One-way 只允许 `BOTH`；Hedge 只允许 `LONG`/`SHORT` 独立腿；负数量不改变 One-way 的 `BOTH`。
- 策略拥有 leverage，未声明为 `1x`；本计划不恢复 Venue/Session 页面杠杆输入。
- Backtest Funding coverage 不完整且已有开仓腿时继续立即失败；不添加 `ignore` 模式。
- RuntimeChannel 不升级 v2、不实现 HA、不持久化 token；断线时 pending call 返回 `Unavailable`，不得跨连接重放。
- 每个任务按 Red → Green → Refactor 执行；测试失败必须确认失败原因为目标缺口，不能先写实现。

## Canonical Interfaces

```proto
enum FuturesPositionSide {
  FUTURES_POSITION_SIDE_BOTH = 0;
  FUTURES_POSITION_SIDE_LONG = 1;
  FUTURES_POSITION_SIDE_SHORT = 2;
}
```

- HTTP Venue/Order JSON：`position_side: "BOTH" | "LONG" | "SHORT"`；不出现 `direction` 或数字值。
- DB：允许 smallint `0/1/2`，仅在 repository 边界与生成 enum 显式转换。
- Session fatal error：`ORDER_REQUEST_REJECTED` 或 `ORDER_EXECUTION_UNKNOWN`，同时保存 `error_message` 与 `error_detail_json`。
- Runtime state：`CONNECTING -> HELLO/RESUME -> READY -> RECONNECTING`；`/healthz` 表示进程存活，`/readyz` 表示当前连接已认证。

## Dependency Waves

1. Wave 1：Task 1（共享 proto/core）、Task 4（Historical Funding）、Task 7（Runtime reconnect）可并行。
2. Wave 2：Task 2（handler/frontend）、Task 3（strategy position side）、Task 5（typed platform/session error）在对应生成代码就绪后并行。
3. Wave 3：Task 6（订单分类）、Task 8（重启验收）、Task 9（完整模式矩阵）、Task 10（干净栈总验收）。

---

### Task 1: 建立唯一 FuturesPositionSide proto 契约

**Files:**

- Modify: `core-service/proto/portfolio_service.proto`
- Modify: `core-service/proto/order_service.proto`
- Add: `core-service/internal/domain/futures_position_side.go`
- Modify: `core-service/internal/service/wallet_state_proto_test.go`
- Modify: `core-service/internal/order/service/grpc_test.go`
- Modify: `core-service/internal/income/position_projection_test.go`
- Regenerate: `core-service/gen/portfoliov1/portfolio_service.pb.go`
- Regenerate: `core-service/gen/portfoliov1/portfolio_service_grpc.pb.go`
- Regenerate: `core-service/gen/orderv1/order_service.pb.go`
- Regenerate: `core-service/gen/orderv1/order_service_grpc.pb.go`

**Step 1: Write failing descriptor and behavior tests**

断言 `PositionEntry.position_side`、`FuturesPosition.position_side`、`FundingPositionLegFact.position_side` 和 order v1 所有 position-side 字段引用同一个 `portfolio.v1.FuturesPositionSide`；断言 `FuturesPosition.direction` 不存在且编号/name 均 reserved。再加入：One-way+BOTH 成功、Hedge+LONG/SHORT 成功、One-way+LONG 和 Hedge+BOTH 在持久化前失败、未知 enum `3` 失败、Hedge+Isolated 同 symbol 两腿不净额。

**Step 2: Run the focused tests and verify RED**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
go test ./internal/service ./internal/order/service ./internal/income
```

预期：descriptor 仍指向旧字段类型/`direction` 尚存在，新增模式断言失败。

**Step 3: Implement the canonical enum**

在 `portfolio_service.proto` 定义枚举，将上述 portfolio/order 字段全部改用它；删除 `FuturesPosition.direction` 并 reserve 字段号 `2` 与字段名。用 domain helper 完成 short label 与 DB smallint 的严格映射，拒绝未知值。通用层不得调用 enum `.String()` 生成 HTTP 值，因为它会产生带前缀的 proto 名。

**Step 4: Regenerate and run GREEN tests**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
make proto
go test ./internal/service ./internal/order/service ./internal/income
go test ./...
go vet ./...
```

**Step 5: Commit**

```bash
git add proto gen internal/domain internal/service/wallet_state_proto_test.go internal/order/service/grpc_test.go internal/income/position_projection_test.go
git commit -m "refactor: centralize futures position side contract"
```

---

### Task 2: Handler 与 Frontend 删除 direction/数字兼容

**Files:**

- Modify: `gateway/quant-handler/internal/app/wallet_bootstrap.go`
- Modify: `gateway/quant-handler/internal/app/portfolios_ext.go`
- Modify: `gateway/quant-handler/internal/app/enum_labels.go`
- Modify: `gateway/quant-handler/internal/app/order_history.go`
- Modify: `gateway/quant-handler/internal/app/session_history.go`
- Add: `gateway/quant-handler/internal/app/wallet_bootstrap_test.go`
- Modify: `gateway/quant-handler/internal/app/venues_test.go`
- Modify: `gateway/quant-handler/internal/app/portfolios_ext_test.go`
- Modify: `gateway/quant-handler/internal/app/order_history_test.go`
- Modify: `gateway/quant-handler/internal/app/session_history_test.go`
- Modify: `gateway/quant-frontend/src/api/client.ts`
- Modify: `gateway/quant-frontend/src/components/VenueManagement.tsx`
- Modify: `gateway/quant-frontend/src/components/OrderTree.tsx`
- Add: `gateway/quant-frontend/scripts/futures-position-side-contract.test.mjs`

**Step 1: Write failing handler/frontend contract tests**

Handler 测试要求 JSON 只接受/输出短字符串 `BOTH|LONG|SHORT`，未知值报可操作错误；One-way 按 `(symbol,BOTH)` 唯一，Hedge 允许同一 symbol 的 LONG 和 SHORT 且按 `(symbol,side)` 去重。Frontend 脚本断言 API 类型无 `direction`/numeric union，表单 key 与模式切换不会丢掉合法 Hedge 双腿。

**Step 2: Verify RED**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/gateway/quant-handler
go test ./internal/app
cd ../quant-frontend
node scripts/futures-position-side-contract.test.mjs
```

**Step 3: Implement strict HTTP mapping and UI state**

`buildFuturesWallet` 返回 error；输入直接写生成 enum。历史/快照统一调用 short-label mapper，不输出 proto 前缀或数字。Frontend 移除 `string|number`、numeric mapping 和 `direction`；React key 使用 `${symbol}:${position_side}`。切换到 One-way 时只保留/生成 BOTH；切换到 Hedge 时不把两腿合并。

**Step 4: Verify GREEN**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/gateway/quant-handler
go test ./...
go vet ./...
cd ../quant-frontend
npm run build
for test_file in scripts/*.test.mjs; do node "$test_file"; done
```

**Step 5: Commit each repository**

```bash
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/gateway/quant-handler add internal/app
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/gateway/quant-handler commit -m "refactor: enforce canonical futures position side"
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/gateway/quant-frontend add src scripts
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/gateway/quant-frontend commit -m "refactor: remove legacy position direction UI"
```

---

### Task 3: Strategy-service 消费共享 enum 并删除跨服务 fallback

**Files:**

- Add: `strategy-service/strategy_service/position_side.py`
- Modify: `strategy-service/strategy_service/wallet_factory.py`
- Modify: `strategy-service/strategy_service/wallet_adapter.py`
- Modify: `strategy-service/strategy_service/wallet/canonical.py`
- Modify: `strategy-service/strategy_service/wallet/portfolio_adapter.py`
- Modify: `strategy-service/strategy_service/wallet/binance.py`
- Modify: `strategy-service/strategy_service/portfolio_client.py`
- Modify: `strategy-service/strategy_service/order_client.py`
- Modify: `strategy-service/strategy_service/platform_proxy.py`
- Modify: `strategy-service/strategy_service/funding_position_tracker.py`
- Modify: `strategy-service/tests/test_wallet_runtime.py`
- Modify: `strategy-service/tests/test_wallet_strict_rules.py`
- Modify: `strategy-service/tests/test_portfolio_snapshot_adapter.py`
- Modify: `strategy-service/tests/test_portfolio_wallet_runtime.py`
- Modify: `strategy-service/tests/test_order_client.py`
- Modify: `strategy-service/tests/test_funding_position_tracker.py`
- Modify: `strategy-service/tests/test_backtest_funding_wallet.py`
- Modify: `strategy-service/tests/helpers/wallet_fixtures.py`
- Regenerate: `strategy-service/strategy_service/gen/portfolio_service_pb2.py`
- Regenerate: `strategy-service/strategy_service/gen/portfolio_service_pb2_grpc.py`
- Regenerate: `strategy-service/strategy_service/gen/order_service_pb2.py`
- Regenerate: `strategy-service/strategy_service/gen/order_service_pb2_grpc.py`

**Step 1: Write failing generated-contract and wallet tests**

断言 Python binding 与 core descriptor 的 enum 全名/值完全一致；canonical wallet 不读取 `direction`；One-way 负数量仍是 BOTH；Hedge LONG/SHORT 独立；Funding tracker 用 enum 选择腿并在 details JSON 输出短 label；Binance adapter 是唯一生成 `positionSide` 的位置。

**Step 2: Verify RED**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q -k "position_side or wallet or funding"
```

**Step 3: Regenerate binding and implement strict helper**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service
PYTHON=.venv/bin/python ./generate_proto.sh
```

`position_side.py` 只包装生成的 pb2 常量/descriptor，提供严格的 enum↔short label；删除跨服务 `direction` fallback。内部 `direction_key` 仅可从 enum 派生。Funding 明细必须先转短 label 再比较，禁止 `str(pb2_value)`。

**Step 4: Verify GREEN**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q
go test ./...
go vet ./...
```

**Step 5: Commit**

```bash
git add gen strategy_service tests
git commit -m "refactor: consume canonical futures position side"
```

---

### Task 4: 修正 Historical Funding scope 与数据库基线

**Files:**

- Modify: `control-panel-service/internal/marketdata/service.go`
- Modify: `control-panel-service/internal/marketdata/service_test.go`
- Modify: `control-panel-service/internal/storage/migrations/0001_current_schema_baseline.sql`
- Modify: `control-panel-service/internal/storage/migration_schema_test.go`

**Step 1: Write failing scope matrix tests**

覆盖：Live Kline 接受；Live Funding 拒绝；Historical Kline 接受并为 Futures 幂等创建 Funding companion；Historical Funding 直接接受且不创建自身 companion；Spot historical Kline 不创建 Funding；空/未知 scope 拒绝。migration test 从 baseline 检查 Funding coverage/task 的合法 kind 与零行空库。

**Step 2: Verify RED**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/control-panel-service
go test ./internal/marketdata ./internal/storage
```

**Step 3: Implement scope-first validation**

先 normalize/validate scope：Live 调 `validateStreamKey`，Historical 调 `validateCoverageKey`。仅 Historical Futures Kline 派生 Funding companion；直接 Funding 请求不递归。不改 scraper 静态 forward/reverse collector 配置。

**Step 4: Verify GREEN and demand-driven routing**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/control-panel-service
go test ./internal/marketdata ./internal/storage
go test ./...
go vet ./...
```

**Step 5: Commit**

```bash
git add internal/marketdata internal/storage
git commit -m "fix: admit historical futures funding requests"
```

---

### Task 5: 为 RuntimeChannel 与 Session 增加结构化错误载荷

**Files:**

- Modify: `strategy-service/proto/runtime_worker.proto`
- Modify: `control-panel-service/internal/runtimechannel/status_patch.go`
- Modify: `control-panel-service/internal/runtimechannel/status_patch_test.go`
- Modify: `core-service/proto/portfolio_service.proto`
- Modify: `core-service/internal/service/grpc.go`
- Modify: `core-service/internal/service/grpc_strategy_test.go`
- Modify: `core-service/internal/repository/repository.go`
- Modify: `core-service/internal/repository/timescale.go`
- Modify: `core-service/internal/repository/session_test.go`
- Modify: `strategy-service/internal/runtimeagent/agent.go`
- Modify: `strategy-service/strategy_service/worker_agent_client.py`
- Modify: `strategy-service/strategy_service/grpc_server.py`
- Regenerate: `core-service/gen/portfoliov1/portfolio_service.pb.go`
- Regenerate: `core-service/gen/portfoliov1/portfolio_service_grpc.pb.go`
- Regenerate: `strategy-service/gen/runtimeworkerv1/runtime_worker.pb.go`
- Regenerate: `strategy-service/gen/runtimeworkerv1/runtime_worker_grpc.pb.go`
- Regenerate: `strategy-service/strategy_service/gen/runtime_worker_pb2.py`
- Regenerate: `strategy-service/strategy_service/gen/runtime_worker_pb2_grpc.py`

**Step 1: Write failing transport and persistence tests**

测试 RuntimeChannel `StreamError.code` 经 agent 后由 `PlatformCallResult` 保留 code/message/detail；Worker typed exception 到 session final status 不丢字段；`UpdateSessionRequest` 能把结构化错误写入现有 `error_code/error_message/error_detail_json`；status patch 转发内嵌字段时不丢失；旧单一 error string 不再作为业务分类来源。

**Step 2: Verify RED**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/control-panel-service
go test ./internal/runtimechannel
cd ../core-service
go test ./internal/service ./internal/repository
cd ../strategy-service
go test ./internal/runtimeagent
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q -k "platform_call or session_error"
```

**Step 3: Extend current protocol without compatibility aliases**

给 `PlatformCallResult` 与 `UpdateSessionRequest` 增加 typed error code/detail 字段并重新生成 binding。runtime-agent 保留现有 `StreamError.code` 并传入 Worker；Python 抛 typed exception。Session progress/final patch 携带结构化字段，control-panel 完整转发，core repository 更新现有列。不得从错误文本反向猜 code。

**Step 4: Verify GREEN**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
make proto
go test ./...
go vet ./...
cd ../control-panel-service
go test ./...
go vet ./...
cd ../strategy-service
PYTHON=.venv/bin/python ./generate_proto.sh
go test ./...
go vet ./...
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q
```

**Step 5: Commit both repositories**

```bash
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service add proto gen internal
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service commit -m "feat: persist typed session errors"
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/control-panel-service add internal/runtimechannel
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/control-panel-service commit -m "fix: preserve typed runtime status errors"
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service add gen internal strategy_service tests
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service commit -m "feat: propagate typed platform errors"
```

---

### Task 6: 区分订单已失败、请求被拒与执行未知

**Files:**

- Modify: `strategy-service/strategy_service/order_client.py`
- Modify: `strategy-service/strategy_service/platform_proxy.py`
- Modify: `strategy-service/strategy_service/grpc_server.py`
- Add: `strategy-service/strategy_service/order_error.py`
- Modify: `strategy-service/tests/test_order_client.py`
- Modify: `strategy-service/tests/test_platform_proxy.py`
- Modify: `strategy-service/tests/test_grpc_server.py`
- Modify: `core-service/internal/order/service/grpc_test.go`
- Modify: `gateway/quant-frontend/scripts/session-error-contract.test.mjs`

**Step 1: Write failing classification tests**

按 gRPC code 建表测试：`InvalidArgument/FailedPrecondition/PermissionDenied/NotFound` 在未持久化时直接产生 `ORDER_REQUEST_REJECTED` 且不调用 Resolve；`Unavailable/DeadlineExceeded/Unknown` 只 Resolve 一次，找不到 attempt 时产生 `ORDER_EXECUTION_UNKNOWN`；已有 FAILED attempt 是可查询、非致命订单结果；未知执行不重放。两条 fatal 路径都让 Session failed，页面能显示结构化原因。

**Step 2: Verify RED**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q -k "order and (reject or unknown or resolve or session)"
cd ../core-service
go test ./internal/order/service
cd ../gateway/quant-frontend
node scripts/session-error-contract.test.mjs
```

**Step 3: Implement one shared classifier**

`order_error.py` 是 direct client 与 platform proxy 的唯一分类器。确定拒绝不 Resolve；传输不确定只 Resolve 一次；只有查到持久化 attempt 才可返回订单业务状态。否则抛 typed fatal exception，交由 Task 5 的 Session 状态链处理。禁止自动 retry place-order。

**Step 4: Verify GREEN**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q
cd ../core-service
go test ./...
go vet ./...
cd ../gateway/quant-frontend
npm run build
for test_file in scripts/*.test.mjs; do node "$test_file"; done
```

**Step 5: Commit**

```bash
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service add strategy_service tests
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service commit -m "fix: fail sessions on unrecorded order outcomes"
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service add internal/order/service/grpc_test.go
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service commit -m "test: lock pre-persistence order rejection"
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/gateway/quant-frontend add scripts/session-error-contract.test.mjs
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/gateway/quant-frontend commit -m "test: lock typed session error display"
```

---

### Task 7: RuntimeChannel 单 supervisor 自动重连

**Files:**

- Modify: `strategy-service/internal/runtimeagent/runtime_channel.go`
- Modify: `strategy-service/internal/runtimeagent/runtime_channel_test.go`
- Modify: `strategy-service/internal/runtimeagent/agent.go`
- Modify: `strategy-service/internal/runtimeagent/agent_test.go`
- Modify: `strategy-service/internal/runtimeagent/local_control.go`
- Modify: `strategy-service/internal/runtimeagent/blocked_worker_integration_test.go`
- Modify: `strategy-service/cmd/runtime-agent/main.go`
- Modify: `strategy-service/cmd/runtime-agent/main_test.go`
- Modify: `control-panel-service/internal/runtimechannel/service.go`
- Modify: `control-panel-service/internal/runtimechannel/registry.go`
- Modify: `control-panel-service/internal/runtimechannel/auth_test.go`
- Modify: `control-panel-service/internal/runtimechannel/connection_ownership_test.go`
- Modify: `control-panel-service/proto/control_panel_service.proto`

**Step 1: Write failing state-machine tests**

测试 HELLO 成功后 EOF，第二条流首帧严格为 RESUME；同时最多一个 stream；当前 generation 的 pending call 立即 `Unavailable` 且不进入新连接；PermissionDenied/FailedPrecondition 不重试；重连时 `/readyz=503`、ACK 后 200；短暂断线不调用 Agent shutdown，SIGTERM/永久错误仍完整 shutdown；Worker 已应用 Income 但旧连接 ACK 失败时，RESUME 后只重发幂等 DATA_ACK 一次。

**Step 2: Verify RED**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service
go test ./internal/runtimeagent ./cmd/runtime-agent
cd ../control-panel-service
go test ./internal/runtimechannel
```

**Step 3: Implement generation-aware supervisor**

把一次性 `Run` 拆成 supervisor + `runConnection`。首次 HELLO，后续 RESUME；每代连接独立 readiness/outbound/pending/context，前代完全退出再建下一代。退避 250ms 起、5s 上限、full jitter、context 可取消且测试可注入，成功后重置。transient：EOF、Unavailable、DeadlineExceeded、临时 ResourceExhausted/网络错误；permanent：InvalidArgument、Unauthenticated、PermissionDenied、FailedPrecondition、NotFound。禁止 RESUME→HELLO fallback。

**Step 4: Preserve workers, token and ACK correctness**

supervisor 仅在 root context 或 permanent error 返回。RESUME 刷新同一 fingerprint TTL，不在 ACK 前旋转导致 token 丢失；control-panel 正常关闭返回 Unavailable，credential revoke 返回 PermissionDenied。认证后立即 heartbeat。Income 只重发 DATA_ACK，不重放平台调用、订单或 worker payload。

**Step 5: Verify GREEN and races**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service
go test ./internal/runtimeagent ./cmd/runtime-agent
go test -race ./internal/runtimeagent ./cmd/runtime-agent
go vet ./...
cd ../control-panel-service
go test ./internal/runtimechannel
go test -race ./internal/runtimechannel
go vet ./...
```

**Step 6: Commit both repositories**

```bash
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service add internal/runtimeagent cmd/runtime-agent
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service commit -m "fix: resume runtime channel without stopping workers"
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/control-panel-service add proto internal/runtimechannel
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/control-panel-service commit -m "fix: distinguish resumable runtime disconnects"
```

---

### Task 8: 自动化真实 control-panel 重启验收

**Files:**

- Add: `hushine-deploy/scripts/test-runtime-channel-restart.sh`
- Add: `hushine-deploy/scripts/runtime-channel-restart.test.sh`
- Modify: `hushine-deploy/Makefile`
- Modify: `hushine-deploy/docs/architecture/runtime-channel.md`
- Modify: `hushine-deploy/docs/runtime-operator-flow.md`

**Step 1: Write a failing harness contract test**

静态/fixture 测试要求脚本记录 runtime container PID、Agent PID、Worker PID、session_id、heartbeat 与 income/indicator cursor；只停 control-panel；断线期检查 health 200、ready 503、Session 仍 running、pending RPC 有界失败；重启后检查 RESUME、ready 200、PID/generation 不变、heartbeat/cursor 前进且 Income 恰好一次。

**Step 2: Verify RED**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/hushine-deploy
bash scripts/runtime-channel-restart.test.sh
```

**Step 3: Implement deterministic harness**

脚本使用当前本地 compose/config 和已有 API，不清理用户环境；超时均显式失败。加入两个负向阶段：credential revoke 后不得重连风暴并安全停止；停机超过 terminal grace 后 RESUME 被拒并安全停止。正常短暂重启阶段不得重建 runtime 容器或 worker。

**Step 4: Run contract and live restart**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/hushine-deploy
bash scripts/runtime-channel-restart.test.sh
make local-start
bash scripts/test-runtime-channel-restart.sh
```

**Step 5: Commit**

```bash
git add Makefile scripts/test-runtime-channel-restart.sh scripts/runtime-channel-restart.test.sh docs/architecture/runtime-channel.md docs/runtime-operator-flow.md
git commit -m "test: automate runtime channel restart recovery"
```

---

### Task 9: Mock Binance、Funding 与钱包完整验收矩阵

**Files:**

- Modify: `core-service/internal/order/executor/binance_test.go`
- Modify: `core-service/internal/order/lifecycle/backtest_matcher_test.go`
- Modify: `core-service/internal/order/lifecycle/ingestor_test.go`
- Modify: `core-service/internal/income/position_projection_test.go`
- Modify: `strategy-service/tests/test_backtest_funding_wallet.py`
- Modify: `strategy-service/tests/test_funding_position_tracker.py`
- Modify: `strategy-service/tests/test_order_client.py`
- Add: `hushine-deploy/scripts/trading-mode-matrix.test.sh`
- Add: `hushine-deploy/scripts/test-trading-mode-matrix.sh`
- Add: `hushine-deploy/docs/test-reports/2026-08-28-trading-mode-matrix.md`

**Step 1: Expand Mock Binance RED matrix**

Spot 与 Futures 分别覆盖 GTC 全成/部分成后继续挂单、IOC 部分成交后撤余量、FOK 全成/无法全成零成交；Futures 再覆盖 reduce-only、平仓、交易所业务拒绝、重复回报幂等。断言 intent/attempt/exchange order/fill 生命周期和 wallet delta，不只断言 HTTP/gRPC 返回。

**Step 2: Add position/margin RED matrix**

矩阵固定覆盖 One-way×Cross、One-way×Isolated、Hedge×Cross、Hedge×Isolated；Hedge 两腿同 symbol 同时存在，逐腿检查 initial margin、realized/unrealized PnL、Funding 与 available/margin/wallet balance。非法 One-way+LONG/SHORT、Hedge+BOTH 在第一订单前失败。多币种 BTCUSDT/ETHUSDT/ZECUSDT 不串账；Spot 无 hedge/cross/leverage/funding。

**Step 3: Add historical Funding cases**

直接 Historical Funding、Futures Kline companion 幂等、Spot 无 companion、Funding 缺失+开仓立即 fail closed、补齐后重跑、至少三天跨多个 settlement。LONG/SHORT 分别按 signed quantity×mark price×rate 计算再汇总，不能先净额。

**Step 4: Implement only defects exposed by this matrix**

每个新增失败先归属 core、adapter、strategy 或 control-panel 边界；修复留在所有权服务，Binance 专有语义只改 Binance adapter/registry。每个修复保留最小回归测试并单独提交。

**Step 5: Run the matrix**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service
go test ./internal/order/... ./internal/income/...
cd ../strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q -k "funding or order or wallet or position"
cd ../hushine-deploy
bash scripts/trading-mode-matrix.test.sh
bash scripts/test-trading-mode-matrix.sh
```

报告逐格记录输入、预期、实际、证据 ID 和误差；任何格未运行即整体未完成。

**Step 6: Commit**

```bash
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service add internal
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service commit -m "test: cover exchange order and futures margin matrix"
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service add strategy_service tests
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/strategy-service commit -m "test: cover funding and position mode matrix"
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/hushine-deploy add scripts docs/test-reports
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/hushine-deploy commit -m "test: add full trading mode acceptance matrix"
```

---

### Task 10: 干净数据库、完整本地栈与最终证据

**Files:**

- Modify: `db/README.md`
- Modify: `hushine-deploy/docs/operations/local-development.md`
- Add: `hushine-deploy/docs/test-reports/2026-08-28-backtest-runtime-recovery-final.md`
- Modify: repository documentation that still describes `direction`, static Funding collection for historical jobs, or one-shot RuntimeChannel

**Step 1: Run repository gates**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/core-service && go test ./... && go vet ./...
cd ../control-panel-service && go test ./... && go vet ./...
cd ../strategy-service && PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q && go test ./... && go vet ./... && bash scripts/runtime-agent-blocked-worker.test.sh && bash scripts/runtime-agent-platform.test.sh && bash scripts/start-bare-runtime-debugpy.test.sh
cd ../gateway/quant-handler && go test ./... && go vet ./...
cd ../quant-frontend && npm run build && for test_file in scripts/*.test.mjs; do node "$test_file"; done
cd ../../hushine-deploy && make test
```

**Step 2: Rebuild only the unlaunched local control_panel database**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/hushine-deploy
make local-stop
docker compose -f deploy/local/docker-compose.yml exec -T timescaledb psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'control_panel' AND pid <> pg_backend_pid()"
docker compose -f deploy/local/docker-compose.yml exec -T timescaledb psql -v ON_ERROR_STOP=1 -U postgres -d postgres -c "DROP DATABASE IF EXISTS control_panel"
make local-ensure-dbs
```

从空库验证 baseline 一次部署成功，Kline/Funding task、coverage 与零行初始状态均可用。不得删除用户要求保留的其他本地数据库卷。

**Step 3: Build instrumented runtime and start the complete stack**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/hushine-deploy
make runtime-image IMAGE_TAG=dev
make local-start
make local-infra-ps
```

确认 PostgreSQL/TimescaleDB、Kafka、ELK、Jaeger、scraper、core、control-panel、handler、frontend、hosted runtime 均 healthy；覆盖率目录持续产生数据。

**Step 4: Run acceptance suites on the clean stack**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/hushine-deploy
bash scripts/test-runtime-channel-restart.sh
bash scripts/test-trading-mode-matrix.sh
make funding-income-service-chain
make funding-income-demo-smoke
make test-runtime-indicator-v2
```

**Step 5: Audit docs and first-party compatibility**

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup
rg -n "direction|position_side.*(int|number)|funding_rate: true|first frame.*HELLO|first message.*HELLO" --glob '*.md' --glob '!**/docs/archive/**' --glob '!**/docs/bug-reports/**'
cd hushine-deploy
make no-first-party-compatibility
```

删除或修正仍把旧契约当现行行为的文档；历史 bug report 与归档保留为历史证据。最终报告列出每个验收命令、退出码、关键记录 ID、模式矩阵、Funding 对账误差、重启期间 PID/generation/cursor 证据，以及未通过项；存在未通过项时不得写“完成”。

**Step 6: Final review and commits**

先运行 `superpowers:requesting-code-review`，修复所有 P0/P1 和本计划范围内 P2，再重跑受影响测试与全量 gate。

```bash
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/hushine-deploy add db/README.md docs
git -C /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/hushine-deploy commit -m "docs: record clean backtest and runtime recovery verification"
```

## Traceability Checklist

- BUG-1 position contract: Tasks 1–3, 9, 10.
- BUG-2 Historical Funding admission/baseline: Tasks 4, 9, 10.
- BUG-3 Funding fail-closed with complete data chain: Tasks 4, 9, 10.
- Order zero-observability: Tasks 5–6, 9–10.
- control-panel restart disconnect: Tasks 7–8, 10.
- One-way/Hedge × Cross/Isolated, mandatory Hedge+Isolated: Task 9.
- Spot/Futures GTC/IOC/FOK and partial/full/reject: Task 9.
- Clean one-shot database deployment: Task 10.
