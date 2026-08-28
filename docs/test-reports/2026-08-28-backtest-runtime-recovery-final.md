# Backtest、Funding、Runtime Recovery 最终验收

验收日期：2026-08-28
工作区：`/Users/xdy/Workplace/hushine-worktrees/medium-cleanup`
分支：各独立仓库 `cleanup/medium-baseline-20260710`

## 结论

当前未推送的 clean commits 通过完整仓库 gate、单库 fresh bootstrap、无缓存
Runtime 镜像构建、完整本地栈、RuntimeChannel 重启、41 单元交易模式矩阵、Funding
service-chain/Demo gate、Indicator V2 和真实 coverage Runtime。未发现未关闭的范围内
Critical、Important 或 Minor 缺陷。

唯一保留边界是已弃用且不再支持的 `strategy-debugger-cli`：active sibling 工作区的唯一 stale-pin
测试依赖历史 strategy-library commit，因此 active 组合是 147 PASS / 1 预期失败；在
精确匹配的历史 sibling worktree 中 148/148 PASS。本次没有给退役工具添加兼容代码。

## 代码与镜像身份

| 仓库 | 验收 HEAD |
|---|---|
| core-service | `78e1bd7665f1885139070842ae89926892b1a770` |
| control-panel-service | `06046b88bd7cd04b6fa16649f4a4b57804102305` |
| strategy-service | `4db93f548b158bcd2b58b3877226733821fda448` |
| strategy-library | `7e182b4520f8a388b1d698a2edcfba563c24e842` |
| golang-lib | `bc2c4adf25d8420417d3192d636c144a9c122674` |
| quant-handler | `0b854121a5eaf5c63b709a3330797381edf602d4` |
| quant-frontend | `48e5fc75bbf665c721a20c59310365a46d71b3d9` |
| scraper | `1d096f93b666b3a3881860e9d4b1cbdaff4225a3` |
| hushine-deploy（本报告提交前） | `2e1db5beb024bd52b86d420905a75a33a4caacf2` |

无缓存构建命令：

```bash
strategy-service/scripts/build_strategy_runtime.sh --all --no-cache --verify dev
```

| 镜像 | Image ID | 结果 |
|---|---|---|
| `hushine/strategy-runtime:executor-dev` | `sha256:b96ecc931b9aa73e67d72a8be1d86ec0e75057c80867ae626512a7a72edc2b3a` | PASS |
| `hushine/strategy-runtime:executor-coverage-dev` | `sha256:4c5a6badef4173bcf80f44b613a063d67b288725296aaf232b700e07916293be` | PASS |

两个镜像的 label 均指向上表 strategy/core/library/golang-lib commit，
`org.hushine.runtime.source-dirty=false`，dependency closure 与 Worker bootstrap verifier 通过。

## Fresh repository gates

除表中明确列为退役边界的 active debugger 诊断外，下表当前仓库 gate 均为本轮重新执行，
退出码均为 `0`。

| 范围 | 命令 / 结果 |
|---|---|
| core-service | `go test ./...` PASS；`go vet ./...` PASS；`go test -run '^$' -tags=integration ./...` PASS |
| control-panel-service | `go test ./...` PASS；`go vet ./...` PASS |
| strategy-service Python | `PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q` — 1326 PASS |
| strategy-service Go | `go test ./...` PASS；`go vet ./...` PASS |
| strategy-service shell | `runtime-agent-blocked-worker.test.sh`、`runtime-agent-platform.test.sh`、`start-bare-runtime-debugpy.test.sh` 全部 PASS |
| strategy-library | managed `pytest` — 990 PASS |
| 已弃用且不再支持的 debugger（诊断，不是发布 gate） | active：`cd strategy-debugger-cli && uv run --frozen --extra test pytest -q`，exit `1`，147 PASS / 1 stale-pin failure；历史匹配：`cd /tmp/task10-debugger-historical-final/strategy-debugger-cli && uv run --frozen --extra test pytest -q`，exit `0`，148/148 PASS |
| quant-handler | `go test ./...` PASS；`go vet ./...` PASS |
| quant-frontend | `npm run build` PASS；每个 `scripts/*.test.mjs` PASS |
| golang-lib | `go test ./...` PASS；`go vet ./...` PASS |
| scraper | `go test ./...` PASS；`go vet ./...` PASS |
| hushine-deploy | `make test` PASS |
| OpenSpec 现有校验 | `openspec validate --all --strict --no-interactive` 退出 0，`No items found to validate.` |

full-core 初次失败于 Session typed-error JSONB 持久化测试：测试将
PostgreSQL JSONB 规范化后的文本与输入字符串直接比较。core commit `9ae1a7e` 改为语义
JSON object 相等，并保留 malformed/scalar/array/null 拒绝。随后 core commit `0efa940`
将当前 raw error 字段的内部旧命名改为 `Text`，不改变 wire、JSON 或 SQL 映射。focused、
full、vet 和 integration compile 均通过。

blocked-worker 初次失败为 601 次 heartbeat 对旧预期 600：生产正确发送一次立即
authenticated heartbeat，然后才是 600 个注入 tick。strategy commit `e3a5335` 将初始心跳与
tick 分开断言；连续 10 次 focused 与所有跟踪 shell gate 通过。strategy commit
`4db93f5` 同步将相同的内部 raw error 字段命名改为 `Text`，行为保持不变。

## 单库 fresh bootstrap

只备份和重建了本机 `control_panel`；备份为
`/tmp/control_panel_pre_task10_20260828_200622.dump`。`portfolio`、`order`、年库和 Docker volume
未删除。

1. `make local-stop` — exit 0。
2. terminate 精确 `control_panel` 连接并 `DROP DATABASE control_panel` — exit 0。
3. `make local-ensure-dbs` — exit 0；control-panel 只应用 `0000` 和 `0001`。
4. 第二次 `make local-ensure-dbs` — exit 0；baseline 已应用，无副作用。
5. live PostgreSQL migration contract test — exit 0；Kline 需非空 interval，Funding 需空 interval，反向组合被拒绝。
6. 在任何服务启动前检查所有 control-panel 业务表，均为零行。

约束与初始状态的可复核命令：

```bash
(cd control-panel-service && \
  CONTROL_PANEL_TEST_DSN='postgres://postgres:postgres@127.0.0.1:5432/control_panel?sslmode=disable' \
    go test ./internal/storage \
    -run '^TestControlPanelMigrationsExposeRuntimeIdentitySchema$' -count=1)

docker compose -f hushine-deploy/deploy/local/docker-compose.yml exec -T timescaledb \
  psql -v ON_ERROR_STOP=1 -U postgres -d control_panel \
  -c 'TABLE schema_migrations'
docker compose -f hushine-deploy/deploy/local/docker-compose.yml exec -T timescaledb \
  psql -v ON_ERROR_STOP=1 -U postgres -d control_panel <<'SQL'
SELECT format('SELECT %L AS table_name, count(*) AS rows FROM %I;', tablename, tablename)
FROM pg_tables
WHERE schemaname = 'public' AND tablename <> 'schema_migrations'
ORDER BY tablename
\gexec
SQL
```

三个命令均 exit `0`；第一个测试同时验证合法 Kline/Funding interval 组合及非法反向组合，
ledger 只有 `0000`/`0001`，最后一个命令的每张业务表均返回 `0`。备份
`/tmp/control_panel_pre_task10_20260828_200622.dump` 非空，当前权限 `0600`。

## 完整本地栈

`make local-start` 后实际 listener 与 pidfile 一致：

| 服务 | PID / 端口 | 结果 |
|---|---|---|
| core-service | `8971` / `50051`, `8080` | running，gRPC listener 归属正确 |
| control-panel-service | `9010` / `50054`, `50055` | health/ready 200 |
| scraper | `9038` | exactly one managed process |
| quant-handler | `9071` / `8090` | HTTP 200 |
| quant-frontend | `9109` / `5173` | HTTP 200 |

TimescaleDB、Kafka、Elasticsearch、Kibana、Jaeger 都为 healthy；Kafka broker API、ELK bridge
索引和 Jaeger OTLP 路径均可用。预检发现三个同 worktree 旧进程占用端口时，未将
旧服务误判为新启动成功；只结束已验证 cwd 属于当前 worktree 的旧进程后重启。
修复前检查还发现两个同 worktree、已失去 pidfile ownership 的旧 scraper（PID `44900`、
`78535`）；停止它们后的中间受管实例是 PID `89550`。`local-start` 现会先执行 `local-stop`，
防止重复启动无监听端口的 scraper 并覆盖其 pidfile；随后连续两次真实 `make local-start` 均
exit `0`，第二次的最终 PID 是表中的 `9038`。新 pidfile 与所有 listener 一致，且 `pgrep`
只剩一个 scraper。对应 Makefile 契约测试验证 stop 调用恰好一次并位于首个 start 之前。

## RuntimeChannel 重启证据

命令 `bash scripts/test-runtime-channel-restart.sh` 退出 `0`。证据文件：
`/private/var/folders/pv/q2dxlrd55lz22mr53zylhpsc0000gn/T/hushine-runtime-restart.Z7emKh/evidence.json`。

- Runtime `selfhosted-I4dnf5X00BNtkfxHXZsx2g`，Session
  `3efe61b46e20e51efce59d7bd22f1f7e`。
- Runtime container / Agent / Worker PID 和 generation 从重启前到恢复后一直为
  `81465 / 1 / 87 / 2752139`。
- health/ready 为 `200/200 → 200/503 → 200/200`；重连首帧为 `RESUME`，不是新
  `HELLO`。lease 只有一行，`issued_at` 不变，owner/`updated_at` 前进，admission failure 0。
- heartbeat cursor `1787919241364028 → 1787919277365205`；Indicator cursor
  `1022 → 1024`；Income cursor `0 → 1001`。
- pending RPC correlation `rpc-004aae5ffbd140d262450498`：从断线请求到 typed
  `Unavailable` 为 `48ms`；10 秒观察窗内 proxy/broker 执行 `1/1`，replay `0`。
- Funding Income `1001` 的预期与 wallet/available/total 实际变化均是
  `-0.000100000000000000 USDT`，误差 `0`，应用次数 `1`。
- credential revoke：Agent exit `1`，reconnect `0`，safe stop；terminal grace：
  `FailedPrecondition`，匹配 admission 尝试 `1`，Agent exit `1`。
- 清理证明 `owned_only=true`、`ownership_validated=true`、`artifacts_removed=true`。

## 交易、Funding 和 Indicator 验收

| 命令 | 退出码 | 关键结果 |
|---|---:|---|
| `bash scripts/trading-mode-matrix.test.sh` | 0 | 矩阵 contract 防伪造/缺失/重复验证 PASS |
| `bash scripts/test-trading-mode-matrix.sh` | 0 | official 41/41 PASS |
| `bash scripts/funding-income-service-chain-contract.test.sh` | 0 | fail-closed contract PASS |
| `bash scripts/funding-income-service-chain.test.sh` | 0 | DB/Mock/order/liquidation/ADL/Funding/runtime chain PASS |
| `bash scripts/funding-income-demo-smoke.test.sh` | 0 | Demo gate contract PASS |
| protected real Demo read-only smoke | 0 | `FUNDING_SMOKE_CREDENTIAL_FD=3 FUNDING_SMOKE_VENUE_ID=4845 FUNDING_SMOKE_SESSION_ID=a6cecd583e3e1676af35049bb308007d bash scripts/funding-income-demo-smoke.sh 3<&3`（FD 3 由调用方匿名 credential pipe 提供）；15 分钟窗内 0 条 |
| `bash scripts/runtime-indicator-v2-smoke.sh` | 0 | DB/service/1023→1025/restart/Windows Bare/handler/frontend PASS |

41 单元覆盖 Spot/Futures GTC、IOC、FOK 的 full/partial/open/expired/zero-fill，Futures
ONE_WAY/HEDGE × Cross/Isolated，BTC/ETH/ZEC 多 symbol，Historical Funding complete/gap/retry，
liquidation/ADL，以及终态 replay 在 runtime/canonical/protobuf/repository/live restart 的一次性。

## 本轮 coverage 证据

命令：

```bash
USER_ID=4059 PORTFOLIO_ID=5545 EXPECTED_INPUT_COUNT=1 \
START_TIME_MS=1787529600000 END_TIME_MS=1787541600000 \
COVERAGE_IMAGE=hushine/strategy-runtime:executor-coverage-dev \
bash scripts/smoke_hosted_runtime_coverage.sh \
  /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/.coverage/runtime-agent
```

退出码 `0`。Runtime `rt-4884ce26164ed5e67a60f124` 通过 Preview，创建并停止两个不同
Session `27cc2f805d10ed00c0a3e75693a5a5f4`、`0db22f37e5bc3ce504a64f70b6da0adb`
及其 Worker generation，拒绝 active Session 期间 EndRuntime，最后正常 EndRuntime。
`finalization.json` 为 `complete`，`worker_shutdown=ok`，`forced_workers=0`，
`go_snapshot=ok`。

- 本轮新增 coverage/report 文件：26。
- Go statements：27.5%。
- Python：4206 / 10476 statements，40.1489%。
- 报告目录：`.coverage/runtime-agent/smoke-reports/rt-4884ce26164ed5e67a60f124`。

第一次尝试用了保留的旧 Portfolio `5190`，core 按当前无兼容契约拒绝其旧
snapshot 中的 `direction` 字段，脚本安全清理了自己的 Runtime，没有产生伪报告。使用
当前契约 Portfolio `5545` 重跑后完整通过。这不是未解决的代码缺陷，而是清理旧协议后
对旧持久化测试数据的预期 fail-closed 边界。

## 文档与兼容审计

现行非 archive/bug-report 文档已审计：

- 订单方向使用 typed side/position side，不再宣称 `direction` 是产品契约；
- Historical Funding 是按 Backtest 需求计划 coverage，不是静态预置全市场任务；
- RuntimeChannel 首次连接是 `HELLO`，已认证断线恢复的首帧是 `RESUME`。

审计还修正了 active wallet bootstrap 文档中的已删除 position 字段、三个 scraper
控制面文档的 Kline-only/静态回退描述，以及 active `e2e_full_flow.sh` 中的旧 Venue payload。
当前 e2e 使用 `position_side: "BOTH"`，不再发送 Venue `direction` 或 `leverage`。

`golang-lib/README.md` 中仍出现的 `"direction": "recv"` 是通用 WebSocket 日志传输方向，
不是已删除的订单 `direction` 字段，因此正确保留。历史 bug report、archive 和日期化
Superpowers/OpenSpec 记录没有伪装成现行运维指南。

## 未通过项与发布判定

- 产品代码、现行 schema、完整栈和验收链路：无未通过项。
- retired debugger 的 active-sibling stale pin：debugger HEAD
  `0ee8597b510afbf572a8170f073c8235c71e01f3` 配 active library
  `7e182b4520f8a388b1d698a2edcfba563c24e842` 时 exit `1`（147/1）；匹配 pin
  `ef9c2435f69ea3be62fd1fc25752b2274d3cadaa` 的保留 worktree 148/148 PASS。该退役工具
不是发布 gate，本轮没有修改或增加兼容。
- 真实 Demo read-only 时间窗内无 Funding 账单，所以只证明安全查询链路；交易所实际
  amount 仍需在下一个真实结算窗口继续观察对账。这是运行证据边界，不是本轮失败。

最终两轮独立复审均为 CLEAN，所有原始及新增的 Critical、Important、范围内 Minor
finding 均已关闭，未留下开放的代码审查项。

结论：当前 commits 已达到 ready-to-push；本报告不执行远程 push。
