# Runtime 操作流程

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
   CONTROL_PANEL_ADDR=host.docker.internal:50054 \
   make smoke-self-hosted-runtime
   ```
4. 远端 Docker：
   ```bash
   CREDENTIAL_FILE=$HOME/.hushine/runtime.cred \
   REMOTE_HOST=<docker-host> \
   REMOTE_USER=<ssh-user> \
   CONTROL_PANEL_ADDR=<mac-lan-ip>:50054 \
   make smoke-self-hosted-runtime
   ```

self-hosted runtime 只连 control-panel RuntimeChannel。不要给用户容器配置
account-service、account-service 承载的 order.v1、Kafka 或数据库地址。

## runtime 失败后的 session 恢复

1. runtime 心跳过期或被停止后，control-panel 会把该 runtime 拥有的
   active session 标记为 `recoverable`。
2. `Account Detail` / `Session Detail` 会显示 `recoverable`、失败原因和
   原 runtime 链接。
3. 用户必须在页面选择一个当前可路由的 runtime，然后点击
   `Resume With New Session`。
4. 新 session 会绑定到所选 runtime；旧 `recoverable` session 保留为审计历史。

不要直接在数据库里把 `recoverable` 改回 `running`。旧 runtime 重新连上也不应自动继续旧 session。

## legacy unbound session

历史上没有 `runtime_id` 的 session 不能再走默认 runtime 兜底。状态、停止、
恢复相关 API 会返回显式的 unbound-session 错误，避免多 runtime 场景误伤。
