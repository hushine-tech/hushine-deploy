# Chrome DevTools 冒烟测试流程

本文档用于在部署完成后，由 Codex 通过 Chrome DevTools 模拟真实用户点击，完成一轮可复现的 UI 冒烟测试。目标不是替代单元测试或完整 E2E，而是在上线前确认核心用户路径、后端链路、日志链路和可观测性没有明显断裂。

## 1. 测试原则

- 以页面操作为主，命令行只用于环境探测、日志查询和结果交叉验证。
- 每个模块至少验证一次真实 UI 加载、用户点击、后端响应、错误展示和可观测性。
- 不把 `npm run build`、`go test` 或 `pytest` 等价为 UI smoke；它们是前置验证。
- 不直接改数据库制造通过结果。需要测试数据时，通过页面或公开 API 创建。
- 发现请求风暴、页面卡 Loading、控制台错误、后端 5xx、ELK 大量错误日志时，停止继续 smoke，先定位问题。

## 2. 前置条件

代码目录应符合 [README.md](../README.md) 的多仓库布局。

服务已启动：

```bash
make ensure-dbs
make build
make start
```

检查端口：

```bash
lsof -nP \
  -iTCP:50051 -iTCP:50053 -iTCP:50054 -iTCP:50055 \
  -iTCP:8090 -iTCP:5173 -iTCP:18080 -iTCP:8082 \
  -sTCP:LISTEN
```

预期：

| 服务 | 端口 |
|---|---|
| `core-service` | `:50051`，`restart.sh` 启动时为 `:18080` |
| `control-panel-service` | `:50054`, `:50055`, `:8082` |
| `strategy-service` | `:50053` |
| `quant-handler` | `:8090` |
| `quant-frontend` | `:5173` |

基础设施可访问：

```bash
curl -fsS http://192.168.88.10:9200 >/dev/null
curl -fsS http://192.168.88.10:16686/api/services >/dev/null
```

测试账号：

```text
username: test-user
password: 123qwe
```

如果目标环境不是共享开发基础设施，把下面地址按实际环境替换：

```text
frontend: http://localhost:5173
handler:  http://localhost:8090
es:       http://192.168.88.10:9200
jaeger:   http://192.168.88.10:16686
```

## 3. Codex 执行提示词

部署完成后，可以把下面这段交给 Codex 执行：

```text
请使用 Chrome DevTools 按 hushine-deploy/docs/chrome-devtools-smoke-test.md 执行一轮 UI 冒烟测试。
测试地址：http://localhost:5173
账号：test-user
密码：123qwe
要求：
1. 真实打开页面并点击，不要只用 curl。
2. 每个页面检查 console error 和 network 失败请求。
3. 对关键业务动作查询 ELK / Jaeger 做交叉验证。
4. 记录每一步结果、失败截图或失败请求。
5. 不要擅自修改数据库绕过问题。
```

## 4. Chrome DevTools 基础检查

1. 打开 `http://localhost:5173`。
2. 登录 `test-user / 123qwe`。
3. 打开浏览器控制台，记录：
   - `console.error`
   - `console.warn` 中明显业务错误
   - 未捕获异常
4. 打开 Network，过滤 `fetch/xhr`，确认：
   - 登录接口返回 200
   - 主页面接口返回 200
   - 没有同一接口在短时间内无限重复请求
   - 没有 401 / 403 / 5xx

如果登录后跳转失败或 token 丢失，停止 smoke，优先检查 `quant-handler` JWT 配置和前端 API base URL。

## 5. 页面加载 Smoke

按左侧一级菜单逐个打开页面：

| 页面 | 验收点 |
|---|---|
| `Account Management` | accounts 表能加载；名称列可点击；mode 显示为可读文本 |
| `Strategy Management` | strategies 表能加载；名称列可点击；创建 tab 可打开 |
| `Market Data` | live stream request、historical coverage、data viewer tab 可切换 |
| `Runtime Management` | all runtimes、create runtime、credentials、failure overview tab 可切换 |
| `Session Management` | sessions 表能加载；过滤项可见；页面只读，不暴露 stop/resume 操作 |
| `Order History` | orders / intents / attempts / fills tab 可切换；能追溯 account/session |
| `Notification Management` | overview、telegram binding、preferences、delivery status tab 可切换 |

每个页面都要记录：

- 页面是否卡在 `Loading...`
- Network 是否有失败请求
- 是否存在请求风暴
- Console 是否有前端异常

请求风暴判定：同一个接口在没有用户操作的情况下，连续 10 秒内明显高于预期频率。允许的轮询必须有明确业务原因，例如运行中的 session/runtime。

## 6. Account / Session Smoke

1. 打开 `Account Management`。
2. 点击一个 `Backtest` account 名称进入详情页。
3. 验证详情页顶部 meta：
   - account name
   - ID
   - mode
   - created time
4. 切换 tab：
   - `Portfolio`
   - `Run Strategy`
   - `Sessions`
5. 在 `Sessions` tab 检查：
   - sessions 表能加载
   - session ID 链接可进入详情
   - runtime 链接可进入 runtime detail
   - 全部为终态 session 时，不应持续 3 秒轮询刷新

Chrome DevTools 验证：

```text
Network -> fetch/xhr -> /api/sessions?account_id=<id>
```

预期：

- 首次进入 Sessions tab 发起一次加载。
- 如果列表全是 `finished/stopped/failed/completed/recoverable`，等待 10 秒不应继续打同一 account sessions 查询。
- 如果存在 `running/stopping` session，可以允许按前端设计频率轮询。

## 7. Runtime Management Smoke

### 7.1 Hosted Runtime

1. 打开 `Runtime Management -> Create Runtime`。
2. 在 `Hosted runtime` 区域填写名称，选择 resource profile。
3. 点击 `Start hosted runtime`。
4. 回到 `All Runtimes`。
5. 验证新 runtime：
   - `source = hosted`
   - `role = executor`
   - `status = ACTIVE`
   - `health = routeable`
   - `runtime_id` 可点击进入详情

runtime detail 验收：

- status 信息完整
- connection 信息完整
- active sessions 可见
- hosted runtime 不应展示 self-hosted install instructions

### 7.2 Self-hosted Executor Runtime

1. 打开 `Runtime Management -> Create Runtime`。
2. 在 `Self-hosted runtime` 区域选择 `Executor`。
3. 生成 credential 并下载 `.cred`。
4. 页面应展示 docker run 指令。
5. 在本机或远端机器按页面指令启动 runtime。
6. 回到 `All Runtimes`，验证：
   - `source = self-hosted`
   - `role = executor`
   - `status = ACTIVE`
   - `health = routeable`

二次查看验收：

1. 点击 self-hosted runtime 进入详情。
2. 点击 `Install instructions`。
3. 验证能再次看到启动命令和 credential 挂载路径。

### 7.3 Self-hosted Debugger Runtime

1. 打开 `Runtime Management -> Create Runtime`。
2. 在 `Self-hosted runtime` 区域选择 `Debugger`。
3. 生成 credential 并下载 `.cred`。
4. 页面应展示 debugger docker run 指令，且包含：
   - `/etc/hushine/runtime.cred` 挂载
   - `/workspace` 挂载
   - debugpy 端口映射，例如 `127.0.0.1:5678:5678`
5. 启动容器后，`All Runtimes` 应显示：
   - `role = debugger`
   - `status = ACTIVE`
   - `health = routeable`

## 8. Mode=0 Backtest Smoke

1. 打开一个 `Backtest` account 详情页。
2. 进入 `Run Strategy` tab。
3. 选择一个 active strategy。
4. 选择 mode=0 的时间范围。
5. 点击 `Run backtest`。
6. 在 runtime 选择弹窗中选择 `executor` runtime。

如果 coverage 不足：

1. 页面应阻止直接开始。
2. 点击 `Download data and run backtest`。
3. 等待下载完成并自动开始回测。

预期结果：

- session 创建成功。
- session 最终进入 `FINISHED`。
- `bars_processed > 0`。
- session detail 可以打开。
- order history 能看到对应 account/session。
- backtest 订单相关通知不会发送 Telegram；用户自定义 `self.notify` 不受此限制。

ELK 查询：

```bash
ES_URL=http://192.168.88.10:9200
TODAY=$(date +%Y.%m.%d)
curl -fsS "$ES_URL/app-logs-$TODAY/_search" \
  -H 'Content-Type: application/json' \
  -d '{
    "size": 20,
    "sort": [{"log_time": {"order": "desc"}}],
    "query": {
      "bool": {
        "must": [
          {"match_phrase": {"message": "RunStrategy"}}
        ]
      }
    }
  }'
```

可接受结果：

- 能查到本次 run/backtest 相关日志。
- 没有连续 5xx。
- 没有 strategy-service uncaught exception。

## 9. Market Data Smoke

### 9.1 Live Stream Request

1. 打开 `Market Data -> Request Live Streams`。
2. 选择：
   - exchange: `binance`
   - market: `futures`
   - symbol: 一个可用 symbol，例如 `ETHUSDT`
   - interval: `1m`
3. 点击 `Request Live Stream`。
4. 查看 request 列表。

预期：

- request 创建成功。
- 默认投放 Kafka live delivery，不需要额外勾选。
- 失败时页面展示明确错误。

### 9.2 Historical Coverage

1. 打开 `Market Data -> Historical Coverage`。
2. 输入 exchange / market / symbol / interval / 时间范围。
3. 点击 coverage 查询。

预期：

- 页面展示 covered / missing segment。
- timeline 可视化展示区间。
- 缺口可点击下载。
- 下载后重新查询，coverage 应更新。

### 9.3 Data Viewer

1. 打开 `Market Data -> Data Viewer`。
2. 输入相同 symbol / interval / 时间范围。
3. 点击加载原始 K 线。

预期：

- 能看到原始 K 线表格。
- 能看到价格图。
- 如果 coverage 显示 complete，但 viewer 查不到数据，停止 smoke，优先查 market-data DB / coverage 算法。

## 10. Debugger Smoke

该流程验证 self-hosted debugger 不是只“连接成功”，而是能真实接收 dataset 并被 IDE attach。

### 10.1 准备 Workspace

1. 打开 `Runtime Management`。
2. 找到 active debugger runtime。
3. 进入 runtime detail。
4. 点击准备调试入口。
5. 验证 `/workspace/self_hosted_strategy.py` 被生成。

预期：

- 如果已有旧 `self_hosted_strategy.py`，再次准备调试会归档旧文件。
- 新模板包含 `MyStrategy` 和标准方法名。

### 10.2 页面下发 Debug Dataset

1. 打开 Backtest account。
2. 进入 `Run Strategy` tab。
3. 选择时间范围。
4. 在 runtime 弹窗中选择 debugger runtime。
5. 点击 `Run debugger` 或 `Load Dataset`。

预期：

- 页面提示 dataset 已下发。
- session 标记为 debugging。
- 不要求此时 IDE 已 attach。

### 10.3 VSCode Attach

容器内执行：

```bash
docker exec -it <debugger-container> \
  hushine-debug replay \
  --debugpy \
  --host 0.0.0.0 \
  --port 5678 \
  --wait
```

VSCode 使用 attach 配置连接：

```json
{
  "name": "Hushine Debugger Attach",
  "type": "debugpy",
  "request": "attach",
  "connect": {
    "host": "127.0.0.1",
    "port": 5678
  },
  "pathMappings": [
    {
      "localRoot": "${workspaceFolder}",
      "remoteRoot": "/workspace"
    }
  ]
}
```

预期：

- VSCode attach 成功。
- 断点命中 `self_hosted_strategy.py`。
- replay 可以重复触发。
- strategy 里的 `self.notify.info(...)` 能发送 Telegram。

## 11. Notification Smoke

1. 打开 `Notification Management -> Telegram Binding`。
2. 生成 bind code。
3. 按页面提示到 Telegram bot 绑定。
4. 点击 confirm。
5. 打开 `Preferences`，确认 system / strategy / custom 开关可保存。
6. 打开 `Delivery Status`，点击发送测试消息。

预期：

- Telegram 收到测试消息。
- 页面 delivery status 更新。
- 如果发送失败，只显示用户级错误，不阻断策略运行。

注意：

- backtest / debugger replay 的订单通知默认不发送，避免消息轰炸。
- 用户自定义 `self.notify` 可以发送，由用户策略自行控制频率。

## 12. Order History Smoke

1. 完成一次 mode=0 backtest。
2. 打开 `Order History`。
3. 查看 intents / attempts / orders / fills。

预期：

- 每条订单能追溯 account。
- 每条订单能追溯 session。
- session 链接可打开 session detail。
- account 链接可打开 account detail。

如果 order 有数据但无法追溯 account/session，停止 smoke，优先查 `core-service` order query response 和前端表格字段。

## 13. Session Detail Smoke

1. 从 Account Detail 或 Session Management 打开一个 session detail。
2. 验证顶部：
   - session id
   - status
   - session type
   - runtime 链接
3. 切换 tab：
   - snapshots
   - reconciliation
   - orders

预期：

- tab 切换不触发整页 reload。
- 表头 sticky。
- 大量数据滚动时只滚动内容区。
- order 行可展开查看详情。

## 14. Observability Smoke

### 14.1 ELK

查询最近 10 分钟错误：

```bash
ES_URL=http://192.168.88.10:9200
TODAY=$(date +%Y.%m.%d)
curl -fsS "$ES_URL/app-logs-$TODAY/_search" \
  -H 'Content-Type: application/json' \
  -d '{
    "size": 50,
    "sort": [{"log_time": {"order": "desc"}}],
    "query": {
      "bool": {
        "must": [
          {"terms": {"level.keyword": ["ERROR", "FATAL"]}}
        ]
      }
    }
  }'
```

验收：

- smoke 期间不应出现新的持续 ERROR。
- 允许历史错误存在，但必须记录是否与本次操作相关。

### 14.2 Jaeger

```bash
HANDLER_URL=http://127.0.0.1:8090 \
JAEGER_URL=http://192.168.88.10:16686 \
ES_URL=http://192.168.88.10:9200 \
bash scripts/verify_tracing.sh
```

验收：

- trace 中至少包含 `quant-handler` 和 `core-service`。
- 涉及 strategy run 时，应能看到 `strategy-service`。
- ES 能用 trace_id 查到对应日志。

## 15. 失败记录模板

每次 smoke 输出一份记录，建议保存到部署工单或 Notion。

```markdown
# Hushine Smoke Report

- 时间：
- 环境：
- commit / image tag：
- 测试账号：
- 执行人：

## 结果

- 总体：PASS / FAIL
- 阻塞项：

## 页面结果

| 页面 | 结果 | 备注 |
|---|---|---|
| Account Management | PASS/FAIL | |
| Strategy Management | PASS/FAIL | |
| Market Data | PASS/FAIL | |
| Runtime Management | PASS/FAIL | |
| Session Management | PASS/FAIL | |
| Order History | PASS/FAIL | |
| Notification Management | PASS/FAIL | |

## 核心链路

| 链路 | 结果 | 证据 |
|---|---|---|
| hosted runtime | PASS/FAIL | |
| self-hosted executor | PASS/FAIL | |
| self-hosted debugger | PASS/FAIL | |
| mode=0 backtest | PASS/FAIL | |
| market-data coverage/download | PASS/FAIL | |
| VSCode debug attach | PASS/FAIL | |
| Telegram notification | PASS/FAIL | |
| ELK logs | PASS/FAIL | |
| Jaeger trace | PASS/FAIL | |

## 失败详情

- 页面：
- 操作：
- 预期：
- 实际：
- console error：
- network request：
- ELK query / trace id：
- 截图：
```

## 16. 通过标准

一轮 smoke 只有在以下条件全部满足时才算通过：

- 所有一级页面能加载。
- 核心页面没有请求风暴。
- Account / Runtime / Session / Order 之间的链接可追溯。
- 至少完成一次 mode=0 backtest。
- 至少验证一次 runtime 创建或连接。
- Market Data coverage 和 viewer 结果一致。
- Notification test message 可发送，或明确记录目标环境未配置 Telegram。
- ELK 没有本次 smoke 引入的持续 ERROR。
- Jaeger trace 链路可查。

如果任何核心链路失败，本轮 smoke 结论必须是 `FAIL`，不能用“其他页面可用”覆盖。
