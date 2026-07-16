# Runtime 操作流程

本文描述当前 RuntimeChannel 实现。所有策略请求和 session 路由都只使用
`runtime_id`；runtime 名称只是展示字段，不能作为路由键。

## Runtime Python 依赖契约

`strategy-library/hushine_strategy/runtime_dependencies.toml` 是唯一手写的
Runtime Python 依赖清单，包含 schema、profile 名称、profile 版本、Hosted /
Debugger Python 约束，以及每个公开 import root。`strategy-service` 和
`strategy-debugger-cli` 的 `pyproject.toml` 生成区块、直接依赖与各自
`uv.lock` 都是该清单的投影，不能直接在生成区块中加依赖。

清单变更规则：

1. 修改 manifest，并把 `profile_version` 提升到严格更大的 SemVer。
2. 用 checker 的 write 模式重新生成两个项目投影，再分别更新 lock。
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

这条命令用于源码开发，不能证明镜像或 debugger 的安装闭包。安装态检查必须
清除 `PYTHONPATH` / `PYTHONHOME` / `VIRTUAL_ENV` 并使用 `python -I`。

## Runtime 启动、HELLO 与 RESUME

1. runtime-agent 从镜像环境读取 profile、commit、build ID 和公开 roots。
2. agent 用安装态 Python 运行 dependency startup probe。失败时进程在建立
   RuntimeChannel 前退出，不会发送 HELLO，也不会启动 worker。
3. Hosted 的单行安全失败记录由 Docker provisioner读取；Self-hosted 只能用
   自己的 credential/mTLS 发送签名的 failure-only report。Bare 不走该上报面。
   失败上报只能记录启动失败，不能注册 runtime、恢复 route 或发送普通帧。
4. probe 成功后，HELLO 对完整 profile 签名。断线恢复时 RESUME 携带同一组
   不可变 profile 字段和 resume token。
5. control-panel 先要求 HELLO/RESUME 完整携带 schema、name、version、digest、
   Python、排序且唯一的公开 roots、service/library commit 和 image build ID；
   再把 schema/name/version/digest 与部署配置精确比较。不完整或不一致都会记录
   `runtime_admission_failures`，route 不会变为 active。

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

## 已保存 Strategy 的只读兼容扫描

上线前可扫描现有未归档策略：

```bash
env -u PYTHONPATH -u PYTHONHOME -u VIRTUAL_ENV \
  strategy-service/.venv/bin/python -I \
  hushine-deploy/scripts/scan-saved-strategy-imports.py \
  --dsn-env PORTFOLIO_READONLY_DSN \
  --output /tmp/hushine-runtime-dependency-scan.json
```

命令行只接收保存 DSN 的环境变量名称，绝不接收或输出 DSN 值。扫描器设置
read-only transaction，只执行一条按 `strategy_id` 排序的 SELECT，以 100 条为
一批读取，并在成功或失败时都 rollback/close。数据库端不会把超过 1 MiB 的
source 返回客户端；客户端只做 `ast.parse`，不会 import/exec 用户源码。

报告将迁移影响分为 `platform_safety`、`dynamic_safety`、`dependency` 三类；
坏行、语法错误、超限源码和单行扫描异常单独记为 `scan_error`，不会中断后续行。
退出码 `0/1/2` 分别表示无 finding、有 finding、扫描报告无法安全完成。

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

1. runtime 心跳过期或被停止后，control-panel 会把该 runtime 拥有的
   active session 标记为 `recoverable`。
2. `Portfolio Detail` / `Session Detail` 会显示 `recoverable`、失败原因和
   原 runtime 链接。
3. 用户必须在页面选择一个当前可路由的 runtime，然后点击
   `Resume With New Session`。
4. 新 session 会绑定到所选 runtime；旧 `recoverable` session 保留为审计历史。

不要直接在数据库里把 `recoverable` 改回 `running`。旧 runtime 重新连上也不应自动继续旧 session。

## legacy unbound session

历史上没有 `runtime_id` 的 session 不能再走默认 runtime 兜底。状态、停止、
恢复相关 API 会返回显式的 unbound-session 错误，避免多 runtime 场景误伤。

## Debugger 与 AGENTS.md rollout handoff

用户 debugger 的标准 bootstrap、profile 检查和修复命令是：

```bash
cd strategy-debugger-cli
uv run --no-project --python 3.13 python init.py
$HOME/hushine-debug-workspace/.venv/bin/python -I \
  -m hushine_debugger.cli profile --json
$HOME/hushine-debug-workspace/.venv/bin/hushine-debug repair \
  --dir "$HOME/hushine-debug-workspace"
```

下面的 block 由 workspace owner 在协调发布完成后原样同步到根
`AGENTS.md`；根目录不是 Git，本变更不会静默修改它：

```bash
# strategy-service source-development regression (not installed closure)
cd strategy-service
PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest tests/ -q

# installed/frozen Runtime and debugger gates; no source shadowing
cd ..
env -u PYTHONPATH -u PYTHONHOME -u VIRTUAL_ENV \
  strategy-service/.venv/bin/python -I \
  -m hushine_strategy.runtime_dependencies verify-installed \
  --python-constraint 3.13 --json
env -u PYTHONPATH -u PYTHONHOME -u VIRTUAL_ENV \
  strategy-debugger-cli/.venv/bin/python -I \
  -m hushine_debugger.cli profile --json

# standalone debugger bootstrap on Python 3.12/3.13/3.14
cd strategy-debugger-cli
INDEX_TREE="$(git write-tree)" \
  bash scripts/bootstrap-standalone.test.sh \
  --library-repo ../strategy-library \
  --expected-library-commit "$(git -C ../strategy-library rev-parse HEAD)"
```

`with-local-strategy-library-git.sh` 只是在未发布 commit 上做 pre-push 验收的
bare-mirror transport。它不能进入 `pyproject.toml`、`uv.lock`、用户 bootstrap
命令或发布文档。协调 push 完成后还必须在无 sibling checkout、无 Git URL
rewrite、全新 HOME/uv cache 的网络环境重跑 bootstrap；该 gate 通过前 release
仍处于 blocked 状态，不能先单独发布 strategy-library。
