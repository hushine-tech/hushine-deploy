# 生产部署 Checklist

本文档用于从 GitHub 多仓库重新部署 Hushine。目标是让部署步骤可重复、可回滚，并在上线前明确验证数据库、Kafka、ELK、Jaeger、runtime 和核心交易链路。

## 1. 代码拉取

在目标机器上保持如下目录结构。`core-service` 仓库需要 clone 到本地目录 `core-service`。

```bash
mkdir -p hushine
cd hushine

git clone git@github.com:hushine-tech/hushine-deploy.git .
git clone git@github.com:hushine-tech/core-service.git core-service
git clone git@github.com:hushine-tech/control-panel-service.git control-panel-service
git clone git@github.com:hushine-tech/quant-handler.git gateway/quant-handler
git clone git@github.com:hushine-tech/quant-frontend.git gateway/quant-frontend
git clone git@github.com:hushine-tech/scraper.git scraper
git clone git@github.com:hushine-tech/strategy-service.git strategy-service
git clone git@github.com:hushine-tech/strategy-library.git strategy-library
git clone git@github.com:hushine-tech/golang-lib.git golang-lib
```

## 2. 基础设施

生产或共享开发环境至少需要以下组件可达：

| 组件 | 默认地址 | 验收命令 |
|---|---|---|
| TimescaleDB/PostgreSQL | `192.168.88.10:5432` | `pg_isready -h 192.168.88.10 -p 5432 -U postgres` |
| Kafka | `192.168.88.10:19092` | `kafka-broker-api-versions --bootstrap-server 192.168.88.10:19092` |
| Elasticsearch | `http://192.168.88.10:9200` | `curl -fsS http://192.168.88.10:9200` |
| Kibana | `http://192.168.88.10:5601` | `curl -fsS http://192.168.88.10:5601/api/status` |
| Jaeger | `http://192.168.88.10:16686` | `curl -fsS http://192.168.88.10:16686/api/services` |
| OTLP HTTP | `http://192.168.88.10:4318` | 通过 `scripts/verify_tracing.sh` 验证 |

如果使用本机隔离环境：

```bash
make local-bootstrap
make local-start
```

## 3. 配置检查

上线前逐个确认：

- `core-service/config.yaml`
  - `database` 指向 portfolio DB
  - `order_database` 或 order module DSN 指向 order DB
  - `notification.kafka.brokers` 指向 Kafka
  - `TELEGRAM_BOT_TOKEN` / `TELEGRAM_BOT_USERNAME` 通过环境变量注入，不提交到仓库
- `control-panel-service/config.yaml`
  - `provisioning.backend` 为 `docker`
  - Mac / Docker Desktop 场景使用 `network_mode: bridge` 和 `runtime_channel_dial_addr: host.docker.internal:50055`
  - Linux 单机可评估 `network_mode: host`，但必须验证容器内能连到 control-panel
  - `runtime_platform` / `runtime_plans` 满足目标环境限额
- `gateway/quant-handler/config.yaml`
  - `control_panel_service_grpc` 指向 control-panel gRPC；strategy RPC routing 不再支持 handler 直连 strategy-service
  - `jwt_secret` 通过环境变量覆盖默认值
- `strategy-service/config.yaml`
  - 只允许 `dependencies.runtime_channel_grpc` 指向 control-panel
    RuntimeChannel（通常 `:50055`）
  - 不得包含 control-panel 普通 gRPC、core/order、数据库、Kafka、account、
    notification 或 tracing endpoint；Hosted/Self-hosted/Bare 都通过
    RuntimeChannel platform call 访问平台能力
- `scraper/config.yaml`
  - market-data DB 指向 `{exchange}_{year}` 年库族
  - Kafka 只用于 scraper/live delivery 需要的路径

### 3.1 Runtime Python 依赖 release gate

依赖契约的唯一手写源是
`strategy-library/hushine_strategy/runtime_dependencies.toml`。上线人必须显式
选择一个已部署、不可变且本地可解析的 40 位 strategy-library commit：

```bash
export RUNTIME_DEPENDENCY_BASE_SHA=<deployed-strategy-library-commit>
test "${#RUNTIME_DEPENDENCY_BASE_SHA}" -eq 40
git -C strategy-library cat-file -e \
  "${RUNTIME_DEPENDENCY_BASE_SHA}^{commit}"
make runtime-dependency-contract \
  RUNTIME_DEPENDENCY_BASE_SHA="$RUNTIME_DEPENDENCY_BASE_SHA"
```

禁止把 `main`、`origin/main`、`HEAD` 或 Makefile 默认值当 baseline。首次发布时
checker 应报告 `baseline.state=introduced`，且唯一 notice 是
`BASELINE_MANIFEST_ABSENT`；之后以已发布 commit 为 baseline 时必须报告
`present`。check 模式不得改写 projection。

`strategy-service` 与 `strategy-debugger-cli` 必须各自把 manifest 的公开依赖
作为 direct dependency 固定在 lock 中。`strategy-library` 不应生成 `uv.lock`。

## 4. 数据库初始化

```bash
make ensure-dbs
```

成功标准：

- `portfolio` migrations 全部 applied/skipped
- `order` migrations 全部 applied/skipped
- `control_panel` migrations 全部 applied/skipped
- `binance_YYYY` / `okx_YYYY` 或指定年库 migrations 全部 applied/skipped

数据库清单见 [db/README.md](../db/README.md)。

## 5. 构建与启动

先从 clean commits 构建 normal/coverage 两个最终 Runtime 镜像并执行闭包验收：

```bash
test -z "$(git -C strategy-library status --porcelain)"
test -z "$(git -C strategy-service status --porcelain)"
test -z "$(git -C golang-lib status --porcelain)"
test -z "$(git -C strategy-debugger-cli status --porcelain)"
make runtime-dependency-acceptance \
  RUNTIME_DEPENDENCY_BASE_SHA="$RUNTIME_DEPENDENCY_BASE_SHA"
```

该命令无缓存构建并验证
`hushine/strategy-runtime:executor-contract` 和
`hushine/strategy-runtime:executor-coverage-contract`，对每个镜像都运行 verifier
和真实 one-shot worker smoke；还检查 profile/digest 相等、build ID 不同、
`source-dirty=false`、coverage 不公开，以及缺失公开 distribution 时 build/startup
都 fail closed。

```bash
make build
make start
```

启动后检查监听端口：

```bash
lsof -nP \
  -iTCP:50051 -iTCP:50054 -iTCP:50055 \
  -iTCP:8090 -iTCP:5173 -iTCP:18080 -iTCP:8082 \
  -sTCP:LISTEN
```

预期：

- `core-service`: `:50051`，`restart.sh` 启动时为 `:18080`
- `control-panel-service`: `:50054`, `:50055`, `:8082`
- `quant-handler`: `:8090`
- `quant-frontend`: `:5173`

## 6. 核心 Smoke

UI smoke must cover the current Portfolio flow: login, Portfolio and Venue creation/binding, Strategy activation, executor Runtime selection, backtest start, Session Detail, Orders, Reconciliation, Market Data, and Notification Management. Record IDs and trace evidence using the current code-census session runbook; the command probes below are prerequisites, not a substitute for UI smoke.

### 6.1 前端/API

```bash
curl -fsS http://127.0.0.1:5173/ >/tmp/hushine_frontend_probe.html
curl -fsS http://127.0.0.1:8090/healthz
```

登录验证：

```bash
curl -fsS -X POST http://127.0.0.1:8090/api/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"username":"test-user","password":"123qwe"}'
```

### 6.2 Hosted Runtime

```bash
USER_ID=<users.id> PROFILE=small IMAGE_TAG=dev make smoke-hosted-runtime
```

成功标准：

- `EnsureHostedRuntime` 返回 `provisioned=true`
- runtime status 为 `active`
- `ValidateCallerToken` 成功
- 结束 runtime 后 Docker 容器被清理

### 6.3 全链路 E2E

```bash
bash scripts/e2e_full_flow.sh
```

该脚本会启动独立端口的 portfolio/control-panel/runtime/handler，创建 Portfolio 和 Venue、创建 hosted runtime、运行 backtest 回测，并检查：

- session 终态为 `finished` 或 `completed`
- `bars_processed = 200`
- `order_fills` 有订单
- `strategy_id` / `portfolio_id` / `user_id` / `session_id` 归属正确
- `portfolio_snapshots` 写入成功

## 7. Tracing / ELK 验收

```bash
HANDLER_URL=http://127.0.0.1:8090 \
JAEGER_URL=http://192.168.88.10:16686 \
ES_URL=http://192.168.88.10:9200 \
bash scripts/verify_tracing.sh
```

成功标准：

- Jaeger API 可达
- 能找到最新 `quant-handler` trace
- trace 中至少包含 `quant-handler,core-service`
- ES `app-logs-*` 可以查到对应 `trace_id` 的日志

如果 ES 为 0：

- 先检查 Kafka topic 是否存在并有消费：
  `app-logs-system`、`app-logs-access`、`app-logs-root`、`app-logs-grpc_access`、`app-logs-grpc_ext`
- 再检查 `kafka-es-bridge` 是否运行、是否有消费错误
- 最后检查服务 `log.kafka.enabled` 和 Kafka broker 地址

## 8. Runtime 清理检查

每次 smoke 或异常退出后确认没有旧 runtime 容器残留：

```bash
docker ps -a --format '{{.ID}} {{.Names}} {{.Status}}' \
  | rg 'hushine-runtime|hushine-debug|rt-' || true
```

如果 control-panel 页面显示 runtime 已取消，但 Docker 还残留，需要优先查：

- `runtime_registry.cleanup_status`
- `runtime_registry.cleanup_reason`
- control-panel 日志里的 `docker rm -f`

## 9. 停止与回滚

停止服务：

```bash
make stop
```

确认端口释放：

```bash
lsof -nP \
  -iTCP:50051 -iTCP:50054 -iTCP:50055 \
  -iTCP:8090 -iTCP:5173 -iTCP:18080 -iTCP:8082 \
  -sTCP:LISTEN || true
```

回滚策略：

- 代码回滚：每个服务 repo 独立回滚到上一 commit/tag
- DB 回滚：默认不做 destructive rollback；新增 migration 需要用新的 migration 修正
- runtime 回滚：先停止所有 active runtime，再把 normal/coverage 镜像、
  control-panel 期望 profile、strategy-service、strategy-library、debugger pin、
  handler/frontend 一起回到同一组已验证版本；禁止只回滚一个镜像

本次 Runtime dependency contract 不包含数据库 migration。不要为该功能执行
DDL 或 destructive rollback。

### 9.1 已保存 Strategy 的只读预检

使用只读 Portfolio 用户和只通过环境变量注入的 DSN：

```bash
env -u PYTHONPATH -u PYTHONHOME -u VIRTUAL_ENV \
  strategy-service/.venv/bin/python -I \
  scripts/scan-saved-strategy-imports.py \
  --dsn-env PORTFOLIO_READONLY_DSN \
  --output /tmp/hushine-runtime-dependency-scan.json
```

退出 `1` 表示报告中存在兼容性 finding，不表示扫描器写过数据库；按
`platform_safety`、`dynamic_safety`、`dependency` 分组评估迁移，`scan_error`
必须逐条处理。退出 `2` 表示配置、连接、transaction、profile 或输出失败，禁止
继续发布。报告和日志不得包含 DSN、源码、异常文本、文件路径或 traceback。

### 9.2 协调上线顺序

1. 冻结新 Runtime provisioning，完成所有仓库 commit；不要先单独 push/publish
   strategy-library。
2. 在同一个协调发布中推送 library、service、debugger pin、control-panel、
   handler 和 frontend，并确认 debugger pin 等于最终 library commit。
3. 先部署理解 dependency profile 字段的 control-panel/proto consumer，再配置
   exact expected profile；随后部署 handler/frontend 的结构化错误支持。
4. 构建并发布 normal/coverage 成对镜像，更新 Hosted provisioning tag，然后
   重启/替换 Runtime；旧 Runtime 不允许在 mismatch 后继续路由。
5. Dependency protocol descriptor gate 通过后，才按单独计划上线 Indicator V2。
   Dependency-only 阶段保留旧 indicator field 15；Indicator V2 最终把 frame 放到
   field 21 并 reserve 15。两次变更前后都要运行 descriptor checksum/proto tests。
6. 执行只读 saved-strategy scan、真实 Preview/Run/download job 和 UI smoke，再
   解除 provisioning 冻结。

pre-push 可以用 `with-local-strategy-library-git.sh` 建立临时 bare mirror，但该
transport 不得进入 project/lock/用户指令。所有仓库协调 push 后，必须在新的
目录、HOME 和 uv cache 中清除 Git URL rewrite、没有 sibling checkout，并用
canonical GitHub URL 重跑 debugger Python 3.12/3.13/3.14 bootstrap。该 no-mirror
network gate 通过前 release 仍为 blocked。

协调 push 后执行（ref 必须是不可变 release branch/tag，不能是移动默认分支）：

```bash
test -n "$DEBUGGER_PUBLISHED_REF"
test -n "$LIBRARY_PUBLISHED_REF"
test "${#DEBUGGER_COMMIT}" -eq 40
test "${#LIBRARY_COMMIT}" -eq 40
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home"

env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 \
  -u GIT_ALLOW_PROTOCOL HOME="$TMP/home" \
  git clone --branch "$LIBRARY_PUBLISHED_REF" \
  https://github.com/hushine-tech/strategy-library.git "$TMP/library"
test "$(git -C "$TMP/library" rev-parse HEAD)" = "$LIBRARY_COMMIT"
env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 \
  -u GIT_ALLOW_PROTOCOL HOME="$TMP/home" \
  UV_CACHE_DIR="$TMP/library-cache" \
  uv run --directory "$TMP/library" --isolated --no-project \
  --with-editable '.[test]' \
  python scripts/check_runtime_dependency_contract.py \
  --baseline-only --baseline-ref "$LIBRARY_COMMIT" --json \
  >"$TMP/library-baseline.json"
jq -e '.ok == true and .baseline.state == "present"' \
  "$TMP/library-baseline.json"

env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 \
  -u GIT_ALLOW_PROTOCOL HOME="$TMP/home" \
  git clone --branch "$DEBUGGER_PUBLISHED_REF" \
  https://github.com/hushine-tech/strategy-debugger-cli.git "$TMP/debugger"
test "$(git -C "$TMP/debugger" rev-parse HEAD)" = "$DEBUGGER_COMMIT"
cd "$TMP/debugger"
INDEX_TREE="$(git write-tree)" \
  env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 \
  -u GIT_ALLOW_PROTOCOL HOME="$TMP/home" UV_CACHE_DIR="$TMP/debugger-cache" \
  bash scripts/bootstrap-standalone.test.sh --network \
  --expected-library-commit "$LIBRARY_COMMIT"
```

## 10. 上线阻断条件

出现以下任一情况，不应继续上线：

- `make ensure-dbs` 失败
- `make build` 失败
- `runtime-dependency-contract` 或成对镜像 acceptance 失败
- checker baseline 使用移动 ref、projection 需要改写，或 installed check 依赖
  `PYTHONPATH`/sibling source shadowing 才能通过
- normal/coverage profile、digest 或源码 commit 不同，build ID 相同，或任一
  release image 标记为 dirty
- saved-strategy scanner 退出 2，或 scan finding 未完成迁移决策
- debugger 最终 pin 不等于 strategy-library 最终 commit，或协调 push 后的
  no-mirror network bootstrap 未通过
- `scripts/e2e_full_flow.sh` 失败
- hosted runtime 不能创建或不能清理
- `quant-handler` 不能通过 control-panel route resolution 跑 session
- Jaeger trace 缺少 `quant-handler` 或 `core-service`
- ES 无法写入服务日志，且 Kafka/bridge 原因未定位
- Docker 上存在无法解释的旧 runtime 容器
