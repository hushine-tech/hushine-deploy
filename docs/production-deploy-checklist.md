# 基础运维与部署 Checklist

最后核验：2026-08-27。

本文覆盖数据库、Kafka、ELK、Jaeger、服务和 Runtime 镜像的当前启动路径。数据库只
支持从空库创建当前 baseline；Live trading 仍受 rollout guard 保护。

## 1. 目录和组件

所有仓库按 `hushine-deploy/README.md` 的 sibling 结构放置。运行环境需要：

| 组件 | 默认本机端口 | 用途 |
|---|---:|---|
| PostgreSQL/TimescaleDB | `5432` | portfolio、order、control_panel、行情年库 |
| Kafka | `19092` | finalized live K-line 与平台日志/通知 |
| Elasticsearch | `9200` | 日志检索 |
| Kibana | `5601` | 日志界面 |
| Jaeger | `16686` | trace 查询 |
| OTLP HTTP | `4318` | trace 接收 |
| core-service | `50051` | `portfolio.v1`、`order.v1` |
| control-panel-service | `50054` / `50055` | 管理 RPC / RuntimeChannel |
| quant-handler | `8090` | 前端唯一 HTTP API |
| quant-frontend | `5173` | Web UI |

## 2. 本机从空环境启动

```bash
make local-stop
make local-infra-reset
IMAGE_TAG=dev make runtime-image
make runtime-images-verify
make local-configs
make local-infra-up
make local-infra-ps
make local-ensure-dbs
make local-ensure-dbs
make local-start
```

`local-infra-reset` 会删除本机 Hushine 的数据库/消息/可观测性 volumes，只能用于可丢弃
环境。`local-configs` 每次重建忽略跟踪的 `config.local.yaml`，不要把机器地址或 secret
提交到仓库。

覆盖率版 hosted runtime 由 `runtime-image` 同时构建。启动 coverage 采集时设置当前
Makefile/脚本使用的 coverage 开关，输出统一写入 `.coverage/`，不写进用户策略目录。

## 3. 数据库

```bash
make ensure-dbs
make db-schema-bundle
```

每个 owner 仓库只保留当前 baseline。第一次运行创建完整 schema，第二次必须无副作用。
对象清单和手工 bundle 见 [`../db/README.md`](../db/README.md)。不得把包含其他 schema
版本的数据库直接交给当前启动脚本。

## 4. 配置边界

- core-service：portfolio/order DB、交易所 endpoint、Kafka notification、Telegram。
- control-panel-service：control DB、Runtime provisioning、RuntimeChannel、market-data
  control；Hosted 容器只得到 RuntimeChannel 地址和 sealed runtime identity。
- quant-handler：只连接 core-service 和 control-panel-service；前端不直连后端服务。
- scraper：行情年库、Binance REST/WS、finalized live K-line Kafka。
- runtime-agent/worker：不接收数据库、Kafka、core/order、账户 credential、notification
  或 tracing endpoint；所有平台调用经过 RuntimeChannel。

`CREDENTIAL_ENCRYPTION_KEY` 和 JWT/Telegram/交易所 secret 必须由 credential manager 或
环境注入，不能出现在 YAML、命令行、日志、截图或 coverage 产物中。

## 5. Runtime 依赖和镜像

公开 Python 依赖唯一手写源为
`strategy-library/hushine_strategy/runtime_dependencies.toml`。当前 Runtime 发布只验收
strategy-service 的安装闭包，并验证 normal/coverage 镜像具有相同 profile、version、
digest 和源码 commit，但不同 build ID。

```bash
export RUNTIME_DEPENDENCY_BASE_SHA=<immutable-40-char-commit>
make runtime-dependency-contract \
  RUNTIME_DEPENDENCY_BASE_SHA="$RUNTIME_DEPENDENCY_BASE_SHA"
make runtime-dependency-acceptance \
  RUNTIME_DEPENDENCY_BASE_SHA="$RUNTIME_DEPENDENCY_BASE_SHA"
```

Release 构建必须来自 clean worktree，且 image label
`org.hushine.runtime.source-dirty=false`。coverage 包只存在于 coverage image，不能成为
用户策略公开 import。

## 6. 启动与健康检查

```bash
make build
make start

curl -fsS http://127.0.0.1:8090/healthz
curl -fsS http://127.0.0.1:5173/ >/dev/null
curl -fsS http://127.0.0.1:9200/ >/dev/null
curl -fsS http://127.0.0.1:5601/api/status >/dev/null
curl -fsS http://127.0.0.1:16686/api/services >/dev/null
```

同时确认 `50051`、`50054`、`50055`、`8090` 和 `5173` 在监听。scraper 必须能写入
目标 `{exchange}_{year}` 年库，并只把 finalized live K-line 发布到当前 Kafka topic。

Hosted Runtime smoke：

```bash
USER_ID=<users.id> PROFILE=small IMAGE_TAG=dev make smoke-hosted-runtime
```

Self-hosted Runtime smoke：

```bash
CREDENTIAL_FILE=$HOME/.hushine/runtime.cred \
RUNTIME_CHANNEL_ADDR=host.docker.internal:50055 \
make smoke-self-hosted-runtime
```

## 7. 功能门禁

提交发布前至少执行：

```bash
make test
make test-runtime-indicator-v2
bash scripts/verify_spot_usdt.sh all-local
bash scripts/e2e_full_flow.sh
bash scripts/verify_tracing.sh
```

页面验收必须覆盖：登录、Portfolio/Venue、Market Data streams、Strategy 激活、Runtime
选择、Preview、Backtest、Demo、Session history/detail、order/fill、wallet、reconciliation、
Indicator 图表和标签、Telegram、Stop/Resume/worker restart。Spot 只展示资产和低买高卖
语义；Futures 验证 cross/isolated、当前支持的 position mode、逐 target leverage 和
BTC/ETH/ZEC 多输入。

Mock Binance 验收必须覆盖 Spot 与 Futures 的 MARKET/LIMIT、GTC/IOC/FOK（Futures 还
包括当前 GTX/GTD 支持）、full/partial/expired/rejected/rate-limit，以及 exact decimal、
fees、risk filter、recovery 和 liquidation lifecycle。

Funding/Income 还必须覆盖 Account Update + REST 合并、REST-only repair、重复/延迟
Income、Backtest 同时刻先结算后 Kline、Spot 零 Funding、blocked Worker 和 worker-only
restart。调度、告警与受保护的真实 Demo gate 见
[`operations/funding-income.md`](operations/funding-income.md)。

## 8. ELK 与 Jaeger

```bash
HANDLER_URL=http://127.0.0.1:8090 \
JAEGER_URL=http://127.0.0.1:16686 \
ES_URL=http://127.0.0.1:9200 \
bash scripts/verify_tracing.sh
```

至少要看到 quant-handler → core-service/control-panel 的当前调用链；日志中使用
`trace_id`、`user_id`、`portfolio_id`、`venue_id`、`session_id`、`runtime_id` 等业务
标识，但不得出现 key、secret、signature、credential 明文或用户源码。

## 9. 停止与故障处理

```bash
make stop
make local-stop
```

停止后确认没有残留 `hushine-runtime` / `rt-*` 容器。Runtime 失联时 Session 应进入
`recoverable`，不得手工改回 `running`；用户选择可路由 Runtime 后通过 Resume 创建
新 Session。数据库 schema 不支持原地回滚；测试环境重建，需保留的数据使用单独迁移。
