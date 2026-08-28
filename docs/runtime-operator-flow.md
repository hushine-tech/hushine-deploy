# Runtime 操作流程

最后核验：2026-08-28。

Futures 杠杆的完整声明、页面、持久化和故障语义见
[`strategy-owned-futures-leverage.md`](strategy-owned-futures-leverage.md)。

本文描述当前 RuntimeChannel 实现。所有策略请求和 session 路由都只使用
`runtime_id`；runtime 名称只是展示字段，不能作为路由键。

## Runtime Python 依赖契约

`strategy-library/hushine_strategy/runtime_dependencies.toml` 是唯一手写的
Runtime Python 依赖清单，包含 schema、profile 名称、profile 版本、Runtime Python
约束以及每个公开 import root。当前运行路径以 strategy-service 的安装闭包和 Runtime
镜像为准，不能直接在生成区块中增加依赖。

清单变更规则：

1. 修改 manifest，并把 `profile_version` 提升到严格更大的 SemVer。
2. 用 checker 的 write 模式重新生成 strategy-service 投影，再更新 lock。
3. 以明确的、40 位且本地可解析的已部署 commit 作为
   `RUNTIME_DEPENDENCY_BASE_SHA`；禁止用 `main`、`origin/main` 或 `HEAD` 代替。
4. 首次引入时 baseline 必须解析成功但不含 manifest，checker 只接受 schema
   1、`1.0.0` 和固定初始 digest，并报告唯一 notice
   `BASELINE_MANIFEST_ABSENT`。稳定运行后 baseline 必须报告 `present`。

本地源码回归仍使用：

```bash
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q
```

这条命令用于源码开发，不能证明 Runtime 镜像的安装闭包。安装态检查必须
清除 `PYTHONPATH` / `PYTHONHOME` / `VIRTUAL_ENV` 并使用 `python -I`。

## Runtime 启动、HELLO 与当前断线语义

1. runtime-agent 从镜像环境读取 profile、commit、build ID 和公开 roots。
2. agent 用安装态 Python 运行 dependency startup probe。失败时进程在建立
   RuntimeChannel 前退出，不会发送 HELLO，也不会启动 worker。
3. Hosted 的单行安全失败记录由 Docker provisioner读取；Self-hosted 只能用
   自己的 credential/mTLS 发送签名的 failure-only report。Bare 不走该上报面。
   失败上报只能记录启动失败，不能注册 runtime、恢复 route 或发送普通帧。
4. probe 成功后，HELLO 对完整 profile 签名。
5. control-panel 先要求 HELLO/RESUME 完整携带 schema、name、version、digest、
   Python、排序且唯一的公开 roots、service/library commit 和 image build ID；
   再把 schema/name/version/digest 与部署配置精确比较。不完整或不一致都会记录
   `runtime_admission_failures`，route 不会变为 active。

第一次连接只发送 `HELLO`。认证成功后，agent 保存 control-panel 返回的短期
fingerprint/lease；瞬时断线由进程内 supervisor 串行重连，后续连接第一帧发送
`RESUME`，不会重用一次性 credential。断线期间 agent health 保持正常、readiness
变为 false；旧 generation 的 pending 平台 RPC 以有界 `Unavailable` 失败，不能在
RESUME 后 replay。认证 RESUME ACK 后 readiness 才恢复，Go Agent 和现有 Python
Worker 都不重建。只有 terminal runtime、credential revoke、过期/无效 fingerprint
或不匹配 dependency profile 才停止重连并安全退出；不得把 terminal session 自动改回
running。

正常与 coverage 镜像必须成对构建、验证和 smoke。两者的 profile/version/
digest/源码 commit 完全相同，build ID 必须不同；`coverage` 只允许作为镜像
内部工具，不能成为用户策略公开依赖。release 镜像的
`org.hushine.runtime.source-dirty` 必须是 `false`。

## 策略创建、校验与执行

Strategy-first 行为没有改变：创建 Strategy 不需要 `runtime_id`，不会隐式创建
Runtime、Session，也不会调用 Runtime 校验。用户在 Preview、Run 或
download-and-run 时显式选择 Runtime。

可选的预校验接口为：

```http
POST /api/strategy/validate-source
Content-Type: application/json

{"runtime_id":"<selected-runtime-id>","source":"<python-source>"}
```

它只按所选 `runtime_id` 路由到现有 worker，成功返回 `ok`、`issues` 和
`runtime_profile`；不创建 Strategy、Runtime 或 Session。`runtime_id` 不能为空，
source 不能为空且 UTF-8 大小不能超过 1 MiB。

Preview、Run 和 download job 的顺序一致：解析显式 Runtime route → worker 做
语法/平台 surface/动态导入/公开依赖校验 → 在隔离安装态 Python 中探测并初始化
import → 成功后才开始 session。同步错误和 download job 轮询错误只暴露以下
安全字段：`code`、`module`、`runtime_profile`、
`runtime_profile_version`、`image_build_id`、`message`。

稳定错误码：

| code | 含义 |
|---|---|
| `UNSUPPORTED_STRATEGY_DEPENDENCY` | 静态 import root 不在公开 profile 中 |
| `STRATEGY_DEPENDENCY_UNAVAILABLE` | 请求的模块在目标 Runtime 安装态不可用 |
| `STRATEGY_IMPORT_FAILED` | 模块存在，但初始化失败；不暴露传递依赖、路径或 traceback |
| `RUNTIME_DEPENDENCY_PROFILE_INVALID` | runtime 本地 profile/安装闭包在 HELLO 前无效 |
| `RUNTIME_DEPENDENCY_PROFILE_MISMATCH` | HELLO/RESUME profile 与 control-panel 期望值不一致 |

## 策略主导的 Futures 杠杆启动

Futures 杠杆只能来自策略声明，固定优先级为 target 的
`ORDER_TARGETS[].leverage`、class `LEVERAGE`、平台默认 `1x`。Spot target
声明 leverage 会在 worker 执行前失败；Spot-only 策略也不能声明全局
`LEVERAGE`。页面没有 Demo、Backtest 或 Resume 的杠杆输入，Start 请求也不
携带杠杆权威值。

Preview 和 Start 都通过 `runtime_id` 选择 Runtime：

1. Preview 创建临时 one-shot worker，解析当前策略，并经 RuntimeChannel 调用
   core-service 的只读 preflight。它只 GET 当前逐 symbol 杠杆，不取 admission、
   不 POST Binance、不写 launch journal/outbox/Session facts，返回后 worker 退出。
2. Start 生成新的 `launch_operation_id`，再创建 one-shot preparation worker。
   这个 worker 重新读取当前 active strategy，返回 source SHA-256、声明、逐 target
   有效杠杆/来源、路由和风险控制，不进入用户 callback。
3. runtime-agent 把 typed commit 通过 RuntimeChannel 交给 control-panel。control-panel
   用已认证 user/runtime 覆盖 route identity，只做字段校验和 relay；它不解析 Python、
   不算优先级，也不接受 runtime payload 里的内部 endpoint。
4. core-service 获取按
   `(exchange, environment, credential_fingerprint, market, symbol)` 唯一的 admission，
   按稳定 route/symbol 顺序执行 read → 必要时 set → readback。rollback obligation
   先写 journal 再 POST；失败时对本次可能改变的 target 逆序 rollback/readback。
5. 全部确认后才在一个 transaction 内创建 pending Session、逐 target facts、转交
   admission holder 并提交 operation。runtime-agent readback 后构造 bootstrap，最后
   才创建正式 session worker。
6. 正式 worker 重新加载策略，并对 source digest、target set、有效值/来源、
   confirmed leverage 和 wallet metadata 做一致性校验；任何 mismatch 都 fail closed。

`environment=0` 使用同一 resolver 和模拟 Futures wallet，不调用 Binance、不取 live
admission；`environment=1` 才执行上面的 Binance Demo 读写；`environment=2` 继续
rollout guarded。Backtest 不提供 leverage override。

rollback 全部确认时不创建可运行 Session，并释放 operation admission。rollback
无法确认时返回 `LEVERAGE_ROLLBACK_FAILED`，operation/admission 保持
`recovery_required`，按 `launch_operation_id` 去重写 durable outbox；不能把这种状态
描述为“账户没有变化”。成功 Session 终止时释放 admission，但不自动恢复 Binance
杠杆。

## Agent 与 worker 隔离

Go runtime-agent 与每个 Python session worker 是两个进程。agent 在
`127.0.0.1:0` 创建随机 loopback TCP listener，worker 通过
`runtime.worker.v1` 双向 gRPC stream 连接。这里不使用 Unix domain socket，
因此不会把 Bare 模式限定在 macOS/Linux；Windows 使用 `.venv/Scripts/python.exe`
和对应进程组/信号实现。

RuntimeChannel heartbeat 由 Go agent 的独立 goroutine 发送。用户策略在 Python
worker 中命中断点或长时间循环不会阻塞 agent heartbeat；它只会阻塞该 session
的 callback/data consumption。Demo/Live 队列仍受 lag/backpressure 限制，长期
阻塞可能让 session failed/recoverable，但不能让 runtime-agent 因 Python GIL 或
用户断点停止心跳。

worker 从白名单构造的干净环境启动，只包含 session/token/loopback agent address、
隔离 HOME/TMP/cache、公开 runtime profile 和三个展示用 runtime facts。它不继承
父进程中的 DB、Kafka、core/order、credential、JWT、tracing 或其他 secret。
Hosted、Self-hosted 与 Bare 都只能通过 RuntimeChannel platform call 访问平台能力。

control-panel 停机时先把 readiness 置为 false、关闭全部 RuntimeChannel stream，
再对 RuntimeChannel 与内部 gRPC server 执行同一个 10 秒有界
`GracefulStop`。如果连接仍卡在 HELLO/认证前或 handler 未返回，超时后会调用
`Stop` 并等待 server 退出，不能让 pre-auth stream 无限阻塞整个服务停机。

真实 restart gate 在已经由 `make local-start` 启动的本地栈运行：

```bash
make runtime-channel-restart-acceptance
```

脚本创建并拥有 disposable credential/runtime/backtest session，只停止
control-panel-service。它记录容器、Agent、Worker PID/进程 generation、Session、
heartbeat/Indicator/Income cursor，证明断线 health/ready、pending RPC 不 replay、
lease 原地 RESUME、cursor 前进和 Funding wallet exactly-once。负向阶段分别撤销另一张
disposable credential，以及用临时 fast-grace control-panel 配置让第三个 runtime 超过
terminal grace；两者都必须无 reconnect storm 并安全停止。清理以随机 owner label、
精确 user/runtime/session/symbol 为边界，不重置共享 database、volume 或无关 Runtime。

## 替换 hosted runtime

1. 打开 `Runtime Management`。
2. 确认旧 hosted runtime 没有 active session；如果有，先在 session 页面
   `Finish` / `Stop`，或用 `Resume With New Session` 迁移到新 runtime。
3. 找到旧 hosted runtime，点击 `End`，确认该 runtime 进入 terminal
   状态，并记录 `ended_at` / `ended_reason`。
4. 再点击 `Start hosted runtime` 创建新 runtime。名称在同一 user 下全
   生命周期唯一；不填写时会自动生成英文名。

控制面不会再用新 runtime 自动覆盖旧 runtime。如果旧 runtime 仍是非
terminal 状态，新建会返回冲突错误，提示先结束旧 runtime。

## 启动 self-hosted runtime

1. 打开 `Runtime Management -> Runtime Credentials`。
2. 生成 `executor` 或 `debugger` credential，下载 `.cred` 文件；私钥只返
   回一次，平台不保存。
3. 本机 Docker：
   ```bash
   CREDENTIAL_FILE=$HOME/.hushine/runtime.cred \
   RUNTIME_CHANNEL_ADDR=host.docker.internal:50055 \
   make smoke-self-hosted-runtime
   ```
4. 远端 Docker：
   ```bash
   CREDENTIAL_FILE=$HOME/.hushine/runtime.cred \
   REMOTE_HOST=<docker-host> \
   REMOTE_USER=<ssh-user> \
   RUNTIME_CHANNEL_ADDR=$MAC_LAN_IP:50055 \
   make smoke-self-hosted-runtime
   ```

self-hosted runtime 只连 control-panel RuntimeChannel。不要给用户容器配置
core-service、core-service 承载的 order.v1、Kafka 或数据库地址。

## runtime 失败后的 session 恢复

1. runtime 心跳过期或被停止时，control-panel 在同一次 terminal 状态写入中向
   `runtime_session_cleanup_outbox` 入队，并立即尝试通知 core；失败会持久化并由
   watchdog 周期重试，control-panel 重启不会丢失。core 会把尚未启动的 pending
   Session 标为 failed 并释放 admission，把 running/stopping Session 标为
   `recoverable` 并继续保留 admission。
2. `Portfolio Detail` / `Session Detail` 会显示 `recoverable`、失败原因和
   原 runtime 链接。
3. 用户必须在页面选择一个当前可路由的 runtime，然后点击
   `Resume With New Session`。
4. Futures Resume 先要求原 Session 的 strategy 仍为 active，并显示只读逐 target
   preview；提交时必须显式携带原 `resume_session_id`，普通 Start 不会自动接管旧
   Session。
5. core 在一个 transaction 内校验旧 Session 属于同一 user、Portfolio、environment
   和 strategy，且来源状态为 stopped/recoverable；然后把 recoverable 来源改为
   `stopped`（`SESSION_SUPERSEDED_BY_RESUME`）、释放旧 admission 并获取新 launch 的
   admission。任一新 admission 冲突会回滚整笔事务，旧 Session 仍为 recoverable。
6. 新 session 绑定到所选 runtime，重新解析当前源码，重新执行 apply/readback、facts
   和 bootstrap，不能复用旧 Session facts 或旧标量；旧 Session 继续作为审计历史。

不要直接在数据库里把 `recoverable` 改回 `running`。旧 runtime 重新连上也不应自动继续旧 session。

## Bare worker-only restart

内部调试命令：

```bash
strategy-service/scripts/restart-bare-worker-session.sh [old_session_id]
```

本地 control endpoint 也是 `127.0.0.1` TCP，不依赖 Unix socket。当前顺序是：

1. 校验旧 session 属于当前 `runtime_id` 与 user；优先取平台事实，平台不支持时才用
   agent 缓存的原始 RunStrategyRequest。
2. 取得旧 worker generation 的 cleanup ownership；此后 IPC disconnect 的通用清理
   必须等待显式 restart 完成，不能抢先删除 indicator 状态。
3. 只停止旧 Python worker，Go agent 和 RuntimeChannel 保持运行，并等待该 generation
   已准入的处理全部 drain。
4. 调用 `FinalizeSession`，等待正在执行的 flush，封存并重试落库 agent 已接收的
   indicator partial tail。
5. 把旧 session 更新为 `recoverable`。
6. 只有 finalization 和状态更新都成功后，才清除旧
   generation、pending/ready/platform-call/run-request/indicator state。
7. 用保留的 run request 创建新 `session_id` 和新 worker，并加载当前本地策略源码。

这不是 RuntimeChannel RESUME，也不是把旧 session 改回 running。如果 indicator
finalization 失败，旧 session 会标为 `recoverable`，agent 保留可重试的 dirty tail，
命令返回错误且不会启动新 worker；再次执行 restart 可以重试 finalization。
同一旧 session 的并发 restart 只允许一个调用执行，其余调用等待并复用同一个
replacement session 结果，不会启动多个新 worker。cleanup 一旦关闭 generation，
已认证帧就始终携带该 generation 指针完成 admission；即使 registry 已删除映射，
迟到 indicator 也不能退化为无门禁写入。
默认策略源码目录为：

```text
.hushine-runtime/strategies/user-<user_id>/strategy-<strategy_id>-<name>-<version>.py
```

## Indicator 在线分块

Python worker 随每根 bar 发送 indicator frame；Go agent 按
`(session_id, stream_key, indicator_key)` 缓冲。默认 1024 点一块、dirty open chunk
每 2 秒同步：

- 1–1023 点是可增长 open chunk。
- 第 1024 点到达时，chunk 0 在内存立即封为 `finalized=true`，并触发 immediate flush。
- 第 1025 点进入 chunk 1。由于 goroutine 调度，持久化请求可能先发送 finalized
  1024、稍后发送 open 1，也可能一个请求同时带两块；两者最终状态等价。
- 同一 series 相同 `market_time_ms` 的重复点不会 dirty；更小时间被拒绝。
- 已 ACK 且没有新点的 1023 open chunk 不会在每个 tick 重复 UPDATE。写失败时保留
  dirty/pending state，后续重试。
- core-service 在一个 DB transaction 中保存一次请求的 definitions/chunks；只有未
  finalized 且 count 单调增加的 row 可以更新，相同 finalized upgrade 只允许内容完全
  相同，finalized row 永不回退。
- terminal finished 会 seal partial tail 并重试；无法确认时改为 `recoverable`。
  failed/stopped/stop_failed 保留原终态，同时报告 finalization 失败。
- restart 与非预期 disconnect 都先关闭 generation 的新准入、等待在途 platform/
  indicator 处理 drain，再 finalization 和 reconciliation；失败保留 buffer 与
  generation 并调度重试。

Spot 的完整 ownership、过滤器、订单、停止与 reconciliation 见
[`spot-usdt.md`](spot-usdt.md)。

## Session 路由约束

所有 Session 必须持有非空 `runtime_id`。状态、停止和恢复 API 对缺少绑定的请求
fail closed，不能在多 Runtime 场景选择默认 Runtime。

Funding Income 的 RuntimeChannel 数据面、持久化 cursor、blocked Worker 与恢复边界见
[`architecture/runtime-channel.md`](architecture/runtime-channel.md)。
