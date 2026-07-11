# Runtime 跨平台沙箱、断线恢复与重启耐久性设计

日期：2026-07-11

状态：设计已在对话中批准；本文档提交后等待实施前最终复核

## 1. 背景

当前 Go runtime-agent 已经替代旧 Python Runtime 客户端，并通过 RuntimeChannel 连接
control-panel-service，再启动 Python session worker 执行用户策略。总体方向正确，但代码中仍有四类
边界没有真正收口：

1. runtime-agent 仍可通过通用日志配置建立 Kafka 连接，Hosted provisioner 还会注入 Kafka、数据库、
   core-service 和 order-service 等内部地址；worker 又继承 agent 的完整进程环境。
2. Go RuntimeChannel 客户端只建立一次连接，瞬时断线后不会使用已有 lease 执行 `RESUME`；未完成的
   platform call 会一直等到自身超时。
3. 调试重启先停止 worker 并清理内存，再持久化状态，可能丢掉 agent 已收到但尚未落库的自定义
   indicator；worker 被断点卡住时也没有有界的 graceful drain。
4. 用户策略与平台凭证虽然分属 Go agent 和 Python worker，但还没有形成可验证的 OS、文件系统、
   进程和网络隔离。原先考虑的 Unix Domain Socket 也无法覆盖 Windows Bare 调试场景。

这不是删除产品功能，而是把已经确认的架构边界落实为代码约束：Runtime 只连接 RuntimeChannel，
worker 只通过 agent 访问平台，Kafka、数据库和内部服务地址只存在于平台服务侧。

## 2. 已批准的关键决策

- Go runtime-agent 是可信进程，持有 RuntimeChannel bootstrap credential、lease 和 TLS 材料。
- Python session worker 及其加载的用户策略属于不可信执行域，不获得平台内部凭证或地址。
- agent 与 worker 统一使用跨平台 loopback TCP，不把 Unix Domain Socket 作为协议前提。
- Hosted 与官方 Self-hosted 镜像必须启用强制 Linux 沙箱；沙箱初始化失败时 fail closed。
- Bare 是受控的本地调试能力，必须支持 Windows、macOS 和 Linux；它保证进程树清理、环境隔离与
  IPC 认证，但不声称能在用户主机上强制执行 Hosted 等级的网络防火墙。
- 用户策略允许访问公网；私网、loopback 非 IPC 端口、链路本地地址、云 metadata 和平台内部网络
  一律阻断。
- RuntimeChannel 瞬时断线或首次 ACK 丢失后使用同一进程内 lease secret 自动 `RESUME`；bootstrap
  credential 不重复消费。
- 调试重启必须先停止生产新事件、排空 worker 输出、最终持久化 agent 已接收的 indicator，再把旧
  Session 标记为 recoverable，最后才允许拉起新 Session。
- Runtime 日志经 worker IPC 和 RuntimeChannel 进入平台日志链路；agent/worker 不直连 Kafka 或
  Elasticsearch。

## 3. 目标与非目标

### 3.1 目标

- 从配置、provisioning 和进程环境三个层面消除 Runtime 对 Kafka、数据库及内部服务的依赖。
- 在不重启 runtime-agent 的前提下恢复 RuntimeChannel 瞬时断线，并快速终止已经失效的调用。
- 在同一 agent 进程持续存活的调试 worker 重启内，保证已接收 indicator 完成最终落库，且任何失败
  都不会误启动第二个 worker。
- 在官方 Linux 执行环境中，把用户策略限制在最小文件、进程、资源和网络权限内。
- 在 Windows Bare 上保留可用的本地调试、worker 重启和心跳解耦能力。
- 保持现有多数据源策略、1024 点 indicator 分块、订单、爆仓处理、通知和所有已确认产品能力不变。

### 3.2 非目标

- 不把 Bare 或用户完全控制的自定义 Self-hosted 主机描述为可由平台强制验证的安全边界。
- 不允许 worker 直接访问 core-service、order-service、control-panel-service、数据库或 Kafka。
- 不在本轮改变策略 API、`INPUTS`、`ORDER_TARGETS`、BUY/SELL 语义或 Portfolio/Venue 模型。
- 不在断线后自动重放无法证明幂等的 order/platform call。
- 不承诺挽救尚停留在被强杀 Python 进程内、从未送达 agent 的事件；该情况必须被明确记录。
- Unix Domain Socket 只可作为未来 Linux 优化，不能成为协议正确性的必要条件。

## 4. 信任边界与执行模式

| 执行模式 | IPC | 环境/凭证隔离 | OS/网络隔离 | Session admission |
|---|---|---|---|---|
| Hosted 官方镜像 | 固定、容器内 loopback TCP | 强制 | Linux 强制，失败即拒绝启动 | `platform_enforced`，正常可路由 |
| Self-hosted 官方镜像 | 固定、容器内 loopback TCP | 强制 | 官方包本地 fail closed；宿主由 operator 控制 | `operator_attested`，用户明确选择该 Runtime 后可路由 |
| Bare（Windows/macOS/Linux） | 动态 loopback TCP | 强制 | 进程树与资源尽力隔离；不承诺主机防火墙 | `trusted_debug`，仅内部调试且受 rollout guard 保护 |
| 自定义/raw Self-hosted agent | 动态或配置的 loopback TCP | agent 可执行的校验 | 平台不可验证 | `unverified`，默认不接收 Session；仅显式内部 override 可放行 |

`sandbox_level` 必须成为 admission 事实，而不是日志文案：`platform_enforced`、
`operator_attested`、`trusted_debug`、`unverified` 四种值由 control-panel-service 持久化并参与路由。
只有平台控制宿主和官方镜像的 Hosted 才能标记 `platform_enforced`。官方 Self-hosted 的签名构建和
本地自检只能证明官方包在可信 operator 假设下按设计启动，不能抵抗恶意宿主机管理员，因此 UI、
路由和审计不得把 `operator_attested` 等同 Hosted。客户端单方面上报不能提升等级。

## 5. 总体数据流

```text
control-panel-service
  RuntimeChannel :50055
          ^
          | mTLS + bootstrap credential / in-memory resume lease
          v
Go runtime-agent（可信）
  - heartbeat / command / platform proxy / log forwarding
  - 不连接 Kafka、DB、core/order 内部地址
          ^
          | authenticated loopback TCP
          | WorkerFrame / AgentFrame
          v
Python session worker + 用户策略（不可信执行域）
  - 只获得最小进程环境
  - 平台调用全部交给 agent
  - Hosted/官方 Self-hosted 仅允许公网 egress
```

runtime-agent 的心跳和 RuntimeChannel receive/send loop 不得运行在 worker goroutine 上。用户代码
进入断点、死循环或十分钟等待时，只会阻塞对应 worker；agent 仍继续心跳、响应 control-plane
命令，并可在 drain 超时后终止该 worker。

仅拆 goroutine 不足以保证隔离。每个 Session 使用独立、有界、分优先级的 mailbox：stop/restart/drain
等 control lane 永远不排在行情数据之后；market-data lane 达到上限时，`SendToWorker` 立即返回该
Session 的 backpressure，不得阻塞 RuntimeChannel receive/supervisor/heartbeat。agent 发送
`DATA_BACKPRESSURE` 并停止确认超过 last accepted sequence 的数据，由现有 delivery lease 保留并在
worker 恢复后重送；若上游已无法保留，则只失败该 Session 并明确记录 `WORKER_BACKPRESSURE`/gap，
不能静默丢 bar 或拖挂其他 Session。worker outbound 同样按 control/order/indicator/log 分级且有界。

## 6. 工作包一：配置、环境与日志隔离

### 6.1 Runtime 配置收口

runtime-agent 不再复用包含 Kafka sink 的通用 `elog.Config`。它使用专用配置结构，只接受：

- RuntimeChannel 地址、runtime identity/profile；
- bootstrap credential、TLS/CA/证书路径；
- worker executable、workspace、资源和沙箱参数；
- console level、RuntimeChannel 日志队列容量等非 endpoint 日志参数；
- Bare 调试所需的显式参数。

解析配置必须执行严格字段校验。地址按字段而不是字符串模糊匹配：唯一允许的平台 endpoint 字段是
`runtime_channel.address`，其值可以是 control-panel-service 的专用 `:50055` 入口；任何额外
control-panel HTTP/gRPC endpoint，以及 `log.kafka`、`kafka_brokers`、数据库/Timescale/PG/DSN、
core/order/account/portfolio/market-data 地址一旦出现在 Runtime 配置中，启动直接失败并给出字段级
错误，不能静默忽略。该地址只由 agent 使用，不进入 worker 环境。

仓库跟踪的 `strategy-service/config.yaml` 保持无 Kafka。开发机上被 Git 忽略的
`config.local.yaml` 不是远程代码事实；实施时删除其中 Runtime Kafka 配置，或迁移为平台服务专用
配置，不把本地秘密提交到 Git。

### 6.2 Hosted provisioning 收口

control-panel-service 的 Docker provisioner 只向 Runtime 注入：

- RuntimeChannel 可达地址；
- runtime ID、profile、sandbox/admission 模式；
- 一次性 bootstrap credential；
- 必要的 TLS 文件挂载或短期材料；
- worker 启动与资源限制参数。

以下字段不得进入 Runtime container：`KAFKA_BROKERS`、任何 `DATABASE_*`、PG/Timescale/DSN、
`CORE_SERVICE_*`、`ORDER_SERVICE_*`、`ACCOUNT_*`、平台 JWT 和其他内部服务地址。现有正向断言这些
字段被注入的测试必须先改为失败测试，再改实现。

平台侧仍保留合法 Kafka 用途：market-data、notification 和 control-panel 日志。此次删除只针对
Runtime 执行域。

### 6.3 Worker 环境白名单

`worker_manager` 不再使用 `os.Environ()` 构造子进程环境，而从空环境开始重建白名单；“白名单”不仅
限制键，还必须重新生成可信值，不能按键从 parent environment 原样复制：

- `PATH`、`PYTHONPATH`、`VIRTUAL_ENV` 只能由受控 Python 安装、strategy-library 和该 Session
  workspace 的规范化路径构造；
- Windows 的 `SystemRoot`、`WINDIR`、`PATHEXT`、`COMSPEC` 等从 OS 可信 API/固定安装事实重建；
- `HOME`/`USERPROFILE` 和临时目录指向该 Session 的隔离目录，不得指向 agent home；locale、timezone
  只接受已校验值；CA store 只挂载公共 CA，不挂 agent client cert/private key；
- 受控 Python/debugpy 参数；
- 明确生成的 `HUSHINE_WORKER_*`、session/runtime identity 与本地 IPC 参数。

`strategy_env` 是唯一允许的用户自定义非秘密环境通道。键和值都需要校验；平台保留前缀、平台
credential 名称、Kafka/DB/内部 endpoint、代理变量中包含私网或内部地址的项必须拒绝。用户自有的
第三方 secret 若需以 `os.environ` 兼容方式使用，必须来自显式的 encrypted strategy-secret 存储，
按 user/strategy/session 作用域授权，由 agent 在 authenticated worker bootstrap 后内存交付并由
worker 设置，不进入 exec 初始环境、命令行、磁盘或日志；没有可用加密存储时该 secret 配置 fail
closed。不能因为名称中包含 `KEY` 就笼统拒绝用户自己的 secret。`extraEnv` 不能绕过同一校验器。
错误必须在 worker 启动前返回，不能删除敏感字段后继续运行造成行为不确定。

### 6.4 结构化日志转发

Python worker 把 stdout/stderr 和结构化策略日志归一成 `LogEvent`，经现有 worker IPC 发给 agent。
agent 转换为新的 RuntimeChannel `RuntimeLogEvent` frame，control-panel-service 再交给平台日志管道。
Go agent 自身日志也使用同一结构化 frame sink，并保留本地 console sink；RuntimeChannel dial/send、
日志 sink 和 dropped-report 自身的错误只能写 console/metrics，不能再次进入同一个 channel queue，
避免发送失败 → 记录日志 → 再发送失败的递归。worker 和 agent 均不持有 Kafka/Elasticsearch endpoint。

worker 侧先使用独立的有界低优先级日志队列，并由调度器保证 control、order、indicator、progress 和
final-status 等功能帧优先；stdout 洪泛只能丢日志，不能阻塞 worker IPC 或 drain。单行大小、每秒
事件数和队列字节数均有上限。断线期间 agent 再使用有界内存日志队列：

- 优先丢弃 DEBUG，再丢弃 INFO；WARN/ERROR 仅在队列完全耗尽时丢弃；
- 恢复后发送一条聚合的 dropped-count 事件；
- 不落盘 RuntimeChannel credential 或原始 secret；
- 日志进入队列前对已知字段和常见 token、credential、API key、Authorization header 模式做脱敏。
  任意编码或拆分后的 secret 无法被通用日志器可靠识别，因此 secret 默认不得被序列化到日志。

## 7. 工作包二：RuntimeChannel 自动恢复

### 7.1 客户端状态机

当前“一次 dial、一次 stream”的实现改为 supervisor：

```text
START
  -> CONNECTING
  -> HELLO_SENT（进程首次连接；已在内存生成 lease secret）
  -> READY（收到 HELLO_ACK 后）
  -> DISCONNECTED
  -> BACKOFF
  -> RESUME_SENT（同一进程已有 lease）
  -> READY

任一状态收到 terminal error -> TERMINAL -> agent 有序退出/等待重新 provision
```

`runOnce` 只负责一条 stream；supervisor 根据错误分类决定重连。指数退避带 jitter，并设置最小值、
最大值和连续失败指标。现有 wire protocol 中 HELLO 和 RESUME 都由
`FRAME_TYPE_HELLO_ACK/RuntimeHelloAck` 确认，本轮继续复用这一 ACK，并新增 handshake kind、
connection generation 和 lease expiry 字段，不引入一个名称相近但不存在的 `RESUME_ACK`。只有收到
与当前 HELLO/RESUME attempt 匹配的 HELLO_ACK 后才发布 ready；现有只在连接建立时关闭一次的
`connected` 信号要替换为可重复状态通知。

### 7.2 Lease 语义

- agent 在首次 `HELLO` 前生成 256-bit CSPRNG lease secret 和 `hello_id`，并只保存在进程内存。
- `HELLO` 通过 TLS 携带一次性 bootstrap credential、`hello_id` 和 lease secret；`hello_id`、secret
  hash、protocol version 必须进入现有 HELLO signature canonical payload，不能作为签名外附加字段。
  control-panel-service 在同一事务中消费 bootstrap credential，并保存绑定 `runtime_id`、证书
  fingerprint、`hello_id` 的 lease secret hash 和 expiry；ACK 只返回 lease metadata，不需要生成
  另一份客户端尚不知道的 secret。
- agent 在首次 ready 前暂存 bootstrap credential。stream 在 ACK 前中断时，先用已有 lease secret
  `RESUME`：若事务已提交则恢复成功；若服务端明确返回该 lease `NotFound`，说明事务未提交，agent
  使用完全相同的 bootstrap credential、`hello_id` 和 lease secret 重试 HELLO。
- HELLO 对相同 credential identity、runtime/fingerprint、`hello_id` 和 secret hash 是幂等的；已消费
  credential 只允许这一完全一致的重试，任何字段不一致都返回 `Unauthenticated`。收到首次
  HELLO/RESUME ACK 后立即从内存清除 bootstrap credential。
- 心跳和成功 `RESUME` 延长同一个 lease 的有效期。
- `RESUME` 不在 ACK 发出前轮换或失效旧 lease，消除“服务端已换 token、ACK 丢失、客户端永久
  无法恢复”的窗口。
- agent 进程重启后没有 raw lease secret，必须使用新 bootstrap credential 重新 provision；不得把
  raw lease secret 写入磁盘或日志。

protocol v2 中 `RuntimeHelloAck` 不再返回 raw resume token，旧 `resume_token` field number 进入
reserved；`RuntimeResume` 才携带内存中的 lease secret。heartbeat 依赖已认证 stream + expected
connection epoch 延长 lease，不重复携带 raw secret。所有这些字段都由 proto 真相源生成，禁止手改
生成物。

清除 bootstrap credential 只指一次性 HELLO 签名材料。RuntimeChannel 重连所需的 mTLS client
certificate/private key 仍由可信 agent 持有到进程结束，永不下发 worker。

若未来需要 token rotation，必须采用 old/new 双 token 有界 grace window，不能恢复 ACK 前先删除
旧 token。

### 7.3 Stream 注册与 generation

每条通过 HELLO/RESUME 认证的 stream 都在数据库事务中对该 runtime 的 `connection_epoch` 执行原子
increment/CAS，并写入 `connection_owner_instance_id` 和 connection ID。返回的 fencing epoch 同时进入
HELLO_ACK 和本机 registration handle。这样经负载均衡重连到另一 control-panel 实例时，两个进程不
会各自把本机 stream 当成全局 current：

- handler defer 只能调用 `UnregisterIfCurrent(runtimeID, registrationHandle)`；旧 stream 延迟退出不能
  按 runtime ID 直接删除新 stream，避免 ABA。
- heartbeat、owner/lease 更新和所有状态修改都携带 expected epoch，并使用数据库
  `WHERE connection_epoch = expected` fencing；affected rows 为 0 时立即把本机 stream 标 stale 并
  关闭。只有当前 registration 可以接收命令和提交 response；旧 stream 的迟到 frame 被拒绝或丢弃并
  记录 stale-generation 指标。
- HELLO/RESUME ACK 丢失后，新连接可以使用同一 lease secret 创建更高 generation；旧半开连接随后
  退出不会影响新连接。
- 跨实例 command routing 读取 owner instance + epoch；任何 dispatch/platform mutation 都在执行前
  再验证 epoch，避免 A 实例半开流在 B 实例 takeover 后继续修改状态。
- replacement、registry 可见性、ACK 顺序和跨实例 fencing 必须有并发测试覆盖，不能依靠 defer
  调用时序。

### 7.4 错误分类与在途调用

可重试：EOF、连接重置、`Unavailable`、临时 deadline、网络中断。

终止重试：`InvalidArgument`、`PermissionDenied`、`NotFound`、`FailedPrecondition`、
`Unauthenticated`，以及 fingerprint/runtime ID 不匹配。唯一例外是首次 ready 前、预生成 lease 的
RESUME 返回 `NotFound`：它进入上一节定义的同一 `hello_id` 幂等 HELLO 分支。终止错误要进入
Runtime 状态和 admission diagnostics，不能无限重试。

stream 断开时，所有 pending platform call 立即以 `Unavailable` 完成；不等各自 deadline，也不
自动重放。调用方可依据自身幂等语义重新发起。order intent 继续依赖既有业务幂等键，RuntimeChannel
不得擅自重放。

agent context cancel 时停止 backoff timer、关闭 stream、失败化 pending call、停止 worker 并有序
退出，避免 goroutine 泄漏。

### 7.5 Worker PlatformCall 授权

worker IPC 握手成功后，agent 为连接建立不可变的 `user_id + runtime_id + session_id + generation`
security context。worker 发来的 `PlatformCall.method + Any` 不能再原样转发：

- agent 使用穷举 method registry 解码已知 request，并按策略运行最小权限只开放行情读取、订单意图、
  用户通知等当前 worker 确实需要的能力；未知 method 默认拒绝。
- request 中的 user/runtime/session/portfolio/strategy 等对象身份必须与 authenticated context 和
  `StartSession` 事实核对；可由 agent 从可信 context 填充的字段不采信 worker 值，冲突值直接拒绝。
- restart、debug replay、admission、credential 和跨 Session 管理能力永不开放为 worker
  PlatformCall。现有 Python RunStrategy 启动/运行路径确实需要 `portfolio.SaveSession` 与受限的
  `portfolio.UpdateSession`，不能一刀切删除：实施前先从 worker call site 生成完整方法清单，这两个
  adapter 只允许 agent 已知的 pending/current Session，由 agent 覆盖 user/runtime/session identity，
  校验合法状态迁移、bars/progress 单调和 environment/profile 不变量。terminal final status、indicator
  和 progress 优先走各自 typed frame，由 agent 的可信 handler 执行受限状态变更。
- control-panel-service 的 platform proxy 保留第二层 user/runtime/session/object authorization，不能
  把 agent 校验当成唯一防线。
- worker connection 关闭或 generation 失效后，其 pending/late call 全部失败；新 worker 不能复用旧
  worker capability。

## 8. 工作包三：Worker drain、调试重启与 Indicator 耐久性

### 8.1 重启事务顺序

调试重启保持 runtime-agent 和 RuntimeChannel 不退出，只更换 worker。固定顺序如下：

1. 校验新 run request、workspace/code revision 和新 Session 信息，但不启动新 worker。core-service 先
   幂等 reserve 新 Session ID；后续 `RunStrategy/SaveSession` 必须使用该 ID，不能由 worker 临时再
   生成另一个 ID。
2. control-panel-service 创建或取得该 old Session 唯一 active 的 `restart_operation_id`，持久化
   old Session、reserved pending new Session ID、run/code revision、phase/version，并以 CAS 设置
   `restart_blocked=true`。guard 未确认前不停止旧 worker。
3. 向旧 worker 发送 `PrepareStop/Drain`：停止接收新 bar、完成当前可完成的回调并冻结新的功能帧。
   worker 的 order/indicator/progress/final 等功能帧使用跨 lane 单调 `worker_sequence`；它必须先按序
   排空这些帧，最后发送带 `last_functional_sequence` 和各 lane watermark 的 `DrainComplete`。日志可
   按策略丢弃但要报告计数。agent 只有在已经接收并处理到全部 watermark 后才确认 drain，
   `DrainComplete` 不能借 control lane 越过积压 indicator。
4. drain 在有界时间内未完成时终止 worker 进程树，记录 `WORKER_DRAIN_TIMEOUT`。这适用于用户代码
   正停在断点或死循环的情况。无论 graceful 还是 hard kill，都要等待 worker 进程退出以及 agent
   侧 IPC receive loop 关闭，建立“不会再接收旧 generation frame”的边界。
5. producer 停止后，agent 对已经收到的 indicator 执行 `FinalizeSession`。
6. indicator 最终持久化成功后，CAS 把 operation 推进到 `RECOVERABLE_READY`，把旧 Session 标记为
   `recoverable`，但在新 worker 确认前继续保持 `restart_blocked=true/resume_allowed=false`，并携带
   正常重启或 drain timeout 原因。此时只有该 operation 预留的 pending new Session ID 可进入
   `STARTING`，任何 old Session resume 都被拒绝。
7. 只有步骤 5、6 均确认后，才 `ForgetSession`、清理旧 worker/session 内存，并通过明确的 Session
   `RunStrategy -> StartSession` 路径使用 operation 中预留的新 Session ID 加载用户目录中的新代码；
   这里不是 RuntimeChannel 的 `RESUME` 握手。新 worker 确认后 operation 才进入 `COMPLETED`，旧
   Session 保留 recoverable 历史状态但写入 `superseded_by_session_id` 且继续不可 resume。

新代码目录仍由受控 workspace resolver 解析，例如 `.hushine-tech/<user_id>/...`；请求中的路径不
能越过该根目录。

### 8.2 失败语义

- drain 超时：允许 hard kill；agent 已接收数据仍必须 finalization。尚在被杀 Python 进程中的事件
  记为“可能未送达”，不得宣称完全无损。
- indicator finalization 失败：仍把旧 Session 显示为 recoverable，但持久化
  `restart_blocked=true/resume_allowed=false`、`FINALIZATION_BLOCKED` 和错误原因，保留 indicator
  buffer/run request。所有 RunStrategy、Session resume 和 route/admission 入口都必须检查该 guard，
  不能由其他入口启动 worker；同一 operation 重试只继续 finalization。
- recoverable/operation 状态更新失败：保留内存状态和已落库 indicator，operation 保持 guarded，
  不启动新 worker，并由 idempotent reconciliation 重试两侧状态收敛。
- 新 worker 启动失败：旧 Session 已 recoverable、indicator 已耐久；operation 保持同一个 pending
  new Session ID 和 run revision，显式重试不得再创建第二条 Session。
- agent 使用 per-session mutex；control-panel 数据库对 active operation 建唯一约束，phase 只能按
  version CAS 前进。重复点击同 operation 返回当前结果；不同 operation 遇到 active guard 返回
  `Conflict`。只有 `RECOVERABLE_READY` 可进入 `STARTING`，启动确认后才进入 `COMPLETED`。

`runtime_restart_operations` 是 restart orchestration 的持久化真相源，Session 表保存用户可见的
`restart_blocked`、`resume_allowed`、operation ID 和 error code。两库无法跨事务提交，因此每个 phase
都使用幂等写与 reconciliation；任何不确定状态默认 blocked，而不是默认可启动。

现有 60 秒整段 restart timeout 不足以覆盖受控 drain、最终落库和状态确认。改为各阶段独立 timeout
加总，并且超时来源进入状态诊断。

### 8.3 1024 点分块不变量

重构不得破坏已经确认的 indicator 行为：

- 每个 Session/indicator 串行处理，完整块固定为 1024 点并标记 immutable/finalized。
- 当已有 1023 点、下一次收到 2 点时，先形成一个 1024 点 finalized chunk，再对余下 1 点建立新的
  partial chunk；不得把 1025 点塞入同一行，也不得继续修改已封块的 1024 点。
- transport 不强制必须调用两次 RPC：如果两点在同一次 snapshot 前到达，一个
  `SaveStrategyIndicators` request 可以按 chunk index 携带“finalized 1024、partial 1”，repository
  在同一事务中按顺序写入；如果 1024 点触发的 immediate flush 已先取得 snapshot，则先提交 1024，
  下一次再提交 1。两种时序的数据库结果必须一致。
- 同一批 1023 点重复同步时，依据每个 series 的 last accepted market-time checkpoint、out-of-order /
  duplicate 判定和 dirty generation 抑制无变化 upsert。
- 正常结束或调试重启时，`FinalizeSession` 把 agent 已接收的最后 partial chunk 封为该旧 Session
  的最终块；新 Session 使用新的 chunk identity，不与旧尾块混写。
- 数据库写入顺序和确认顺序必须与 finalized 1024、partial 1 一致；失败重试依靠 chunk identity 和
  version 保持幂等。

## 9. 工作包四：跨平台 IPC 与完整沙箱

### 9.1 Loopback TCP IPC

agent 启动本地 TCP listener，且只能绑定 loopback：

- Bare 使用 OS 分配的动态端口，避免 Windows/macOS 端口冲突。
- Hosted/官方 Self-hosted 镜像使用容器内部固定端口；端口绝不 publish 到宿主机。
- 绑定到 `0.0.0.0`、`::` 或非 loopback 地址直接失败。

每次 worker 启动生成 256-bit CSPRNG one-time token，逻辑绑定 session ID、agent 持有的 worker
process handle/cgroup identity 和启动 generation。token 不进入命令行、环境变量、磁盘或日志，而由
agent 通过跨平台匿名 stdin bootstrap pipe 一次性写给刚启动的 worker；worker 在加载用户代码前
读取并完成握手，随后关闭 bootstrap pipe。agent 只接受首个匹配连接，成功后销毁 token。worker
自报 PID 只用于诊断；PID namespace 下 agent 和 worker 看到的数字可以不同，不作为跨平台协议硬
条件。支持可靠 peer-process 查询的平台可把 peer 与已启动 process handle/cgroup 做额外交叉验证。
安全性来自不可猜 token、单次使用、短有效期、process-generation 绑定、loopback/firewall 限制和
先握手后加载用户代码。

worker protocol frame 必须包含 session ID 和 generation，旧 worker 的迟到 frame 不能污染新
Session。agent 对 frame 类型、session ownership、payload 大小、队列深度和发送速率做上限校验，
不能因为本地连接就无条件信任 Python worker。listener 还要限制未认证连接数、每 IP/进程连接速率
和握手 deadline；认证前只读取固定上限的 handshake frame，抵抗 loopback fd/内存洪泛。

### 9.2 官方 Linux 进程与文件系统沙箱

官方 Linux 镜像明确采用最小特权的 `hushine-sandboxd` launcher，而不是要求普通 runtime-agent 在
运行期突然获得 root 权限：

1. `hushine-sandboxd` 作为容器 PID 1 启动，验证 cgroup v2 delegation、namespace、seccomp、mount
   和 firewall prerequisite，随后启动无 capability 的非 root runtime-agent。
2. sandboxd 与 agent 只共享一个启动时继承、worker 看不到的私有 control FD；不挂 Docker socket，
   不暴露网络 listener。该 Linux 内部 helper channel 不属于跨平台 agent-worker protocol。
3. 镜像启动时 sandboxd 仅获得明确列出的 `CAP_SYS_ADMIN`、`CAP_SETUID`、`CAP_SETGID` 和初始化网络
   所需 `CAP_NET_ADMIN`，以及可写的 delegated cgroup v2 subtree；不使用 `--privileged`。它按配置的
   最大并发 worker 数预创建固定 slot 的 UID/cgroup/network class 和 nftables/tc 规则，再永久 drop
   `NET_ADMIN`；后续 launch 只分配空闲 slot。sandboxd 仅保留创建后续 mount/PID namespace、切换
   UID/GID 和管理 delegated cgroup 所必需的 capability。agent 和 worker 从不获得这些 capability，
   slot 耗尽时 admission 返回资源不足而不是无配额启动。
4. 每次 launch 由 sandboxd 创建 cgroup 和 namespace、准备只读 mount tree、切到 worker UID/GID、
   设置 `no-new-privileges`/rlimit/seccomp、drop child 全部 capability，再 exec Python；返回给 agent 的
   是 opaque process/cgroup handle。
5. helper 校验所有 path、resource 和 argv，只实现 launch/terminate/query 三类窄接口，本身无网络并
   使用 read-only 配置。任一 prerequisite 或 launch 步骤失败都返回结构化错误且不 exec worker。
   sandboxd/PID 1 异常退出会让容器整体退出并清理 worker cgroup；agent control FD 断开时立即停止
   admission 并上报 Runtime unhealthy。

Hosted 和官方 Self-hosted worker 由该 launcher 建立以下边界：

- 独立非 root UID/GID，与 agent UID 分离；
- `no-new-privileges`、受控 seccomp、禁用 ptrace、mount、raw socket、BPF、keyring 等无关能力；
- 独立 PID/mount namespace，使 worker 看不到 agent 进程、环境和 credential 文件；
- read-only root filesystem，仅 workspace、受控临时目录和必要 cache 可写；
- workspace 路径归一化与 symlink escape 检查；
- CPU、内存、进程数、打开文件数、磁盘临时空间、网络连接/带宽和执行时间限制；
- 终止时清理整个 cgroup/process tree，而不是只杀 Python 主 PID。

官方部署必须显式提供 cgroup v2 delegated subtree 和上述 capability；缺失时 readiness/admission
fail closed，不能回退为直接 `exec.Command`。Self-hosted operator 需要接受这些 prerequisite，或选择
明确标记为 `unverified` 的自定义模式。

### 9.3 公网允许、内网拒绝的网络策略

用户选择的是“允许公网、阻断私网”。因此硬保证限定在内核可验证的目的 IP/网段和资源配额，不虚假
声称 nftables 能在允许任意公网 TCP 的同时识别所有域名。worker 必须满足：

- 拒绝 RFC1918、CGNAT、loopback（本 worker IPC 端口除外）、link-local、multicast、benchmark、
  documentation/reserved 和 IPv6 对应非公网网段；
- 显式拒绝云 metadata 地址，包括 `169.254.169.254` 及云厂商 IPv6/域名入口；
- 拒绝 cluster/service CIDR、Docker bridge、宿主 gateway 与所有平台内部地址；内部服务不得同时
  暴露在 worker 可达的公网地址上；
- 常规 DNS 只能访问受控 resolver；无论使用该 resolver、硬编码 IP、DNS rebinding 或 DoH，最终连接
  仍由内核目的 IP 规则检查，解析成私网/metadata 的连接无法建立；
- 禁止 raw socket；非 DNS UDP 默认拒绝；公网 TCP 按策略允许，以覆盖 HTTPS/WSS 和用户公开 API；
- worker UID 只可访问 agent 的单一 IPC 端口，不能扫描 agent 的其他 loopback 端口。
- 对 worker cgroup/UID 设置最大并发连接、连接建立速率和带宽配额，agent/RuntimeChannel traffic 享有
  独立队列与更高优先级，恶意公网洪泛不能耗尽宿主 fd/带宽并拖掉 heartbeat。

官方 Linux 镜像使用 worker UID/cgroup 定向的 nftables/netfilter + tc 规则，使 agent 不受 worker
egress 限制并仍能连接 RuntimeChannel。测试必须验证 IPv4、IPv6、直接 IP、域名重绑定和 redirect
后最终目的地址，不能只检查 URL 字符串。

公网域名、DoH 和公网代理都可能到达其他公网服务，也允许用户代码外传其自身可见数据；共享 CDN IP
无法用 L3/L4 规则按域名区分。如果未来必须阻断特定公网平台域名，只能引入强制 L7 egress proxy /
SNI-Host policy 或改为公网 allowlist，这与本轮“任意公网 API 可达”不是同一策略。

### 9.4 Windows 与 macOS Bare

- Windows 使用专用 launcher 以 `CREATE_SUSPENDED` 创建 worker，在任何用户代码运行前执行
  `AssignProcessToJobObject`，成功后才 `ResumeThread`；Job 设置 `KILL_ON_JOB_CLOSE`、禁止 breakaway
  并限制进程/内存。若 agent 已位于不兼容的父 Job 或 nested-job 能力不足，Bare 启动明确失败，不
  采用先运行再 Assign 的竞态降级。IPC 使用动态 loopback TCP，不依赖 Unix socket、fork、Unix UID
  或 `/proc`。
- Windows workspace 通过打开 handle 后的最终路径做边界校验，拒绝逃出用户根目录的 junction /
  reparse point、UNC/device path、alternate data stream、跨 volume 跳转，并按大小写不敏感语义比较；
  不能把 POSIX `realpath`/symlink 检查直接照搬。
- macOS/Linux Bare 使用等价的进程组清理和资源限制能力。
- 所有 Bare 平台仍执行环境白名单、IPC token、session generation 和路径边界。
- 因平台不能安全修改用户主机防火墙，Bare 标记 `trusted_debug`；UI、状态和文档不得显示
  `network sandbox enforced`。

## 10. 测试与验收

实施采用先失败测试、再实现的顺序。最低验收矩阵如下。

### 10.1 配置与环境

- Runtime 配置出现 Kafka、DB 或内部 endpoint 时启动失败。
- Hosted provisioner 测试证明不会注入上述字段，只注入 RuntimeChannel 和必要身份/TLS。
- parent environment 和 `extraEnv` 中放入 canary secret，worker 策略确认不可见。
- Windows/POSIX 最小环境均能启动 Python worker；合法 `strategy_env` 可见，保留键被拒绝。
- agent/worker 日志可到 control-panel，Kafka 不可从 Runtime 建连，脱敏和队列降级行为可观察。
- 强制 RuntimeLogEvent send 失败时只增加 console/metric 和 dropped counter，不递归产生无限日志 frame，
  功能 frame 仍优先发送。

### 10.2 RuntimeChannel

- 首次 HELLO 只有 ACK 后 ready。
- HELLO 在提交前或提交后丢失连接时，客户端分别通过同一 `hello_id` 幂等 HELLO 或预生成 lease
  secret 的 RESUME 恢复，不产生第二条 lease。
- stream 瞬断执行 backoff + RESUME，agent 不退出、worker 不重启、心跳恢复。
- RESUME 对应的 HELLO_ACK 丢失后，同一 lease 仍可再次 RESUME。
- 半开旧 stream 被新 generation 替换后，旧 handler 的迟到 frame/defer 不得删除或污染新 stream。
- A 实例保留半开流、B 实例完成 RESUME takeover 后，A 的 heartbeat/platform response 因 DB fencing
  epoch 失败而关闭，不能反复覆盖 owner 或状态。
- terminal 认证/绑定错误不重试；pending call 立即 `Unavailable`；无 goroutine 泄漏。
- agent 进程重启不复用落盘 lease，使用新 bootstrap credential。

### 10.3 Worker、重启与 indicator

- 精确验证 `persist restart guard -> Get/prepare -> drain/stop -> SaveIndicators(finalized) ->
  UpdateSession(recoverable+blocked) -> operation RECOVERABLE_READY -> StartSession -> COMPLETED` 的顺序。
- drain 成功、断点卡住超时、finalization 失败、状态更新失败、新 worker 启动失败分别验证状态和内存
  保留。
- 人为积压 indicator/order queue 后触发 restart，`DrainComplete` 必须晚于最后 functional sequence，
  agent 到达 watermark 后才 Finalize，最终保存包含最后一帧。
- finalization 失败、重复点击、并发不同 operation、步骤 6→7 窗口和 start 失败时，所有入口都不能
  绕过 guard；重试复用同一 pending new Session ID，成功后 old Session 写入 superseded 事实。
- 1023 后新增 2 点生成 finalized 1024 + partial 1；重复 1023 不重复写；restart 封存尾块。
- 用户策略执行十分钟阻塞/断点期间持续灌入行情直到该 Session mailbox 满：runtime heartbeat、其他
  Session 和 RuntimeChannel 继续工作，control lane 仍可下发 restart，数据进入明确 backpressure/gap
  语义而不是拖挂 agent。
- 伪造 user/runtime/session、跨 Session 对象、未知 method 和 debug/restart 管理 method 的 worker
  PlatformCall 均被两层拒绝；合法 `SaveSession`/受限 `UpdateSession`、RunStrategy、Stop 和爆仓状态
  迁移仍通过。
- 多 `INPUTS`（同币种不同 interval、不同币种）和回测爆仓后的既有表现做回归，确保沙箱与重启
  改造没有改变策略语义。

### 10.4 沙箱与跨平台

- worker 可访问受控公网测试 endpoint，不能访问私网、agent 非 IPC 端口、平台内部地址、metadata、
  Docker gateway 或 DNS-rebinding 后的私网目的地址。
- IPC 在网络规则启用后仍工作；无正确 token、错误 session/generation、过期 token 均被拒绝。
- 恶意 loopback 连接洪泛和公网连接/带宽洪泛达到 quota 时，agent fd/heartbeat SLO 与其他 Session
  不受影响。
- worker 无法读取 agent `/proc`、credential mount 和非 workspace 文件，无法创建 raw socket、
  ptrace agent 或越界写文件。
- 强制破坏任一 sandboxd prerequisite/launch 步骤，Hosted 拒绝 admission、官方 Self-hosted 本地启动
  fail closed；agent 不直接 exec worker。
- `GOOS=windows` 构建只是静态门槛；还必须在 Windows CI/VM 原生运行 integration smoke，覆盖动态
  loopback、suspended Job assignment、nested Job 失败、junction/reparse/path escape 和进程树清理。
- 提供跨平台统一 runtime-agent CLI 或 PowerShell 启动入口；Windows 用户不依赖 `.sh`。

### 10.5 仓库级验证

- strategy-service：Python 全量 pytest、Go `test`/`vet`/`-race`、两套 tracked shell test。
- control-panel-service：Go `test`/`vet`/`-race`，provisioning 与 RuntimeChannel integration test。
- 官方 Runtime 镜像 build 与 mode 0/mode 2 smoke；`environment=2` 继续受 rollout guard 保护。
- root full-flow、multi-input、liquidation、notification 和 debugger smoke。
- `openspec validate --all --strict --no-interactive`。
- 所有测试结果、未覆盖的宿主机限制和沙箱 capability 写入交付报告，不以单元测试代替真实容器
  smoke。

## 11. 实施顺序与提交边界

实施按以下独立 review/commit 边界进行，每包先增加失败测试：

1. Runtime 专用配置、Hosted provisioning 和 worker environment/secret 收口。
2. worker/platform 日志有界队列和 RuntimeChannel structured log。
3. RuntimeChannel protocol v2：client-generated lease、幂等 HELLO、统一 HELLO_ACK。
4. reconnect supervisor、数据库 fencing epoch、跨实例 registry 和 PlatformCall capability registry。
5. restart operation/schema/全入口 guard，再实现 drain、indicator finalization 和幂等 StartSession。
6. 4a：跨平台 loopback IPC token、connection/session generation 与 listener DoS 限制。
7. 4b：Linux sandboxd、mount/PID namespace、filesystem、seccomp 与 cgroup process/resource boundary。
8. 4c：Linux egress 网段规则、连接/带宽 quota 与 backpressure integration。
9. 4d：Windows suspended Job launcher、路径边界、PowerShell/统一 CLI 和 Windows VM smoke。
10. 4e：admission level、UI/diagnostics、部署和全部矩阵回归。

本项目尚未正式上线，RuntimeChannel protocol v2 执行明确 hard cut：HELLO 必须声明 v2 并包含
`hello_id`/lease secret；旧 agent 返回 `FailedPrecondition: upgrade required`，不设计含糊的“可连接但
部分可用”状态。一次部署顺序固定为数据库 migrations/baseline → control-panel/core v2 readiness →
官方 agent 镜像 v2 → 开启 Session admission。根部署入口必须按 health/readiness 自动完成该顺序。

数据库改动至少包括：

- control-panel：lease `hello_id/secret_hash`、runtime `connection_epoch/owner_instance_id`、
  `sandbox_level`，以及 `runtime_restart_operations` 和唯一 active-operation/CAS 约束；
- core-service Session：`restart_blocked`、`resume_allowed`、`restart_operation_id`、error code、
  `superseded_by_session_id` 与对应约束/索引；
- 旧行 backfill 为 `sandbox_level=unverified`、`connection_epoch=0`、`restart_blocked=false`、
  `resume_allowed=true`。Hosted 只有 sandboxd 自检完成后才升级为 `platform_enforced`。

service migrations、当前 schema baseline、`db/generated` bundles 和 `db/README.md` 必须同步。验收既要
覆盖从当前 schema 原地升级，也要覆盖空数据库一次执行全量 DDL 后直接启动完整链路；不能依赖手工
补列、修改旧环境或二次部署。

## 12. 文档与事实源更新

实现完成并验证后，同步更新 Notion 三大块：

- 基础运维：官方 Runtime 镜像、sandbox prerequisite、RuntimeChannel/TLS、网络策略、Windows Bare
  限制、日志链路和故障排查。
- 代码结构和逻辑：信任边界、HELLO/RESUME 状态机、worker IPC、restart drain、1024 分块、各执行
  模式 admission 与 fail-closed 行为。
- 用户手册：Hosted/Self-hosted/Bare 的用途、公网访问范围、策略环境变量、断点后重启命令、
  recoverable 状态和已知限制。

旧 Notion 页面只有逐段与当前代码、测试和本设计核对后才能保留引用。Account-era、旧 Python
Runtime、Runtime 直连 Kafka/DB 和把 Bare 描述为生产安全沙箱的内容必须删除或明确标记历史。

活动 OpenSpec `stabilize-self-hosted-runtime-recovery-and-delivery` 在实施时同步改为当前 Go agent
事实，并记录稳定 in-process lease、跨平台 TCP IPC、drain/finalize 顺序和 sandbox capability；
严格校验通过后才可归档。

## 13. 主要受影响代码

- `strategy-service/internal/runtimeagent/config.go`
- `strategy-service/internal/runtimeagent/observability.go`
- `strategy-service/internal/runtimeagent/runtime_channel.go`
- `strategy-service/internal/runtimeagent/worker_manager.go`
- `strategy-service/internal/runtimeagent/agent.go`
- `strategy-service/strategy_service/session_worker_entry.py`
- `strategy-service/scripts/start-bare-runtime-debugpy.sh`
- `strategy-service/cmd/hushine-sandboxd`（新增 Linux launcher）和 Windows launcher/PowerShell 入口
- `control-panel-service/internal/provision/docker.go`
- `control-panel-service/internal/runtimechannel/service.go`
- `control-panel-service/internal/runtimechannel/auth.go`、registry/platform proxy 和 storage migrations
- `core-service` Session domain/repository/service、storage migrations 和 proto
- `quant-handler` / `quant-frontend` 的 sandbox level、restart guard 与诊断展示
- RuntimeChannel / worker protobuf 及其生成物
- `hushine-deploy` 官方 Runtime 镜像、数据库 baseline/generated DDL、网络规则、运行手册和 smoke tests

最终精确文件清单以先写出的失败测试和实现依赖图为准；不得借本设计删除已确认保留的产品能力。

## 14. 已知限制与安全结论

- Hosted 在平台控制宿主上达到 `platform_enforced`。官方 Self-hosted 只能在可信 operator 假设下
  由官方包本地 fail closed，并标记 `operator_attested`；平台不能远程证明宿主管理员没有篡改内核、
  容器或网络。自定义/raw agent 才是 `unverified`。
- Bare 的目的是真实本地调试，不是承载不可信第三方代码；Windows/macOS 上的网络访问由用户主机
  权限决定。
- hard kill 可以保证 agent 和平台继续可用，但无法恢复从未离开被杀 Python 进程的数据。本文的
  indicator 耐久保证严格限定为“调试 worker restart 且同一 agent 进程持续存活”：agent 已接收的
  frame 会 finalization；agent crash、terminal channel 导致退出或宿主掉电时，尚在内存且未落库的
  frame 仍可能丢失。本轮不新增加密本地 WAL/spool，也不宣称 agent crash-safe。
- 公网访问扩大了策略能力，也保留数据外传风险；用户策略本身属于用户代码。平台秘密、内部网络和
  其他租户数据必须依靠凭证隔离、文件隔离和 egress 规则保持不可达。
- 允许任意公网 TCP 意味着用户策略可以访问公网平台域名、DoH 或公网代理；L3/L4 沙箱保证的是平台
  私网/metadata/宿主边界不可达，而不是公网域名审查。公网服务仍必须依靠正常认证授权。
- 只有上述验收全部通过，Hosted 才能宣称 `platform_enforced`，官方 Self-hosted 才能宣称
  `operator_attested`；否则必须 fail closed 或清晰显示 `unverified`，不能静默运行。
