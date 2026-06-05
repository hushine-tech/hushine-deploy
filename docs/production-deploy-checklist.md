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
  - `database` 指向 account DB
  - `order_database` 或 order module DSN 指向 order DB
  - `notification.kafka.brokers` 指向 Kafka
  - `TELEGRAM_BOT_TOKEN` / `TELEGRAM_BOT_USERNAME` 通过环境变量注入，不提交到仓库
- `control-panel-service/config.yaml`
  - `provisioning.backend` 为 `docker`
  - Mac / Docker Desktop 场景使用 `network_mode: bridge` 和 `control_panel_dial_addr: host.docker.internal:50054`
  - Linux 单机可评估 `network_mode: host`，但必须验证容器内能连到 control-panel
  - `runtime_platform` / `runtime_plans` 满足目标环境限额
- `gateway/quant-handler/config.yaml`
  - `control_panel_service_grpc` 指向 control-panel gRPC；strategy RPC routing 不再支持 handler 直连 strategy-service
  - `jwt_secret` 通过环境变量覆盖默认值
- `strategy-service/config.yaml`
  - `core_service_grpc`、`account_service_grpc` 和 `order_service_grpc` 都指向 `core-service:50051`
  - `control_panel_service_grpc` 可达
  - `log.kafka.enabled` 与目标日志策略一致
- `scraper/config.yaml`
  - market-data DB 指向 `{exchange}_{year}` 年库族
  - Kafka 只用于 scraper/live delivery 需要的路径

## 4. 数据库初始化

```bash
make ensure-dbs
```

成功标准：

- `account` migrations 全部 applied/skipped
- `order` migrations 全部 applied/skipped
- `control_panel` migrations 全部 applied/skipped
- `binance_YYYY` / `okx_YYYY` 或指定年库 migrations 全部 applied/skipped

数据库清单见 [db/README.md](../db/README.md)。

## 5. 构建与启动

```bash
make build
make start
```

启动后检查监听端口：

```bash
lsof -nP \
  -iTCP:50051 -iTCP:50053 -iTCP:50054 \
  -iTCP:8090 -iTCP:5173 -iTCP:18080 -iTCP:8082 \
  -sTCP:LISTEN
```

预期：

- `core-service`: `:50051`，`restart.sh` 启动时为 `:18080`
- `control-panel-service`: `:50054`, `:8082`
- `strategy-service`: `:50053`
- `quant-handler`: `:8090`
- `quant-frontend`: `:5173`

## 6. 核心 Smoke

UI 冒烟测试以 Chrome DevTools 真实页面操作为准。完整流程见
[Chrome DevTools 冒烟测试流程](chrome-devtools-smoke-test.md)。下面命令行
检查只作为前置探测和交叉验证，不能单独替代 UI smoke。

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

该脚本会启动独立端口的 account/control-panel/strategy/handler，创建 hosted runtime，运行 mode=0 回测，并检查：

- session 终态为 `finished` 或 `completed`
- `bars_processed = 200`
- `order_fills` 有订单
- `strategy_id` / `account_id` / `user_id` / `session_id` 归属正确
- `account_snapshots` 写入成功

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

最近一次本地源码服务 + 远端基础设施验收结果：

- 时间：2026-05-23
- 命令：
  `HANDLER_URL=http://127.0.0.1:8090 JAEGER_URL=http://192.168.88.10:16686 ES_URL=http://192.168.88.10:9200 SLEEP_AFTER_FIRE=10 bash scripts/verify_tracing.sh`
- 结果：
  - Jaeger trace id: `a6332419d44245b21d936a774be32bc0`
  - trace services: `core-service,quant-handler`
  - ES `app-logs-*` 命中：`3`

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
  -iTCP:50051 -iTCP:50053 -iTCP:50054 \
  -iTCP:8090 -iTCP:5173 -iTCP:18080 -iTCP:8082 \
  -sTCP:LISTEN || true
```

回滚策略：

- 代码回滚：每个服务 repo 独立回滚到上一 commit/tag
- DB 回滚：默认不做 destructive rollback；新增 migration 需要用新的 migration 修正
- runtime 回滚：先停止所有 active runtime，再切换镜像 tag 和服务版本

## 10. 上线阻断条件

出现以下任一情况，不应继续上线：

- `make ensure-dbs` 失败
- `make build` 失败
- `scripts/e2e_full_flow.sh` 失败
- hosted runtime 不能创建或不能清理
- `quant-handler` 不能通过 control-panel route resolution 跑 session
- Jaeger trace 缺少 `quant-handler` 或 `core-service`
- ES 无法写入服务日志，且 Kafka/bridge 原因未定位
- Docker 上存在无法解释的旧 runtime 容器
