# 本地开发 / Local Development

最后核验：2026-08-28。

本流程只使用本机 Docker 基础设施。服务 source-default 配置不是本地运行的权威输入；
生成的 private local config 和显式环境覆盖才是。

## 组件与启动

`make local-infra-up` 启动 PostgreSQL/TimescaleDB、Kafka、Elasticsearch、Kibana 和
Jaeger。`make local-configs` 生成权限为 `0600` 的 ignored local config 和开发 mTLS
证书。常用路径：

```bash
make local-configs
make local-infra-up
make local-infra-ps
make local-ensure-dbs
make local-ensure-dbs
make local-dev
```

第一次 `local-ensure-dbs` 从各 owner 的 current baseline 一次创建当前 schema；第二次
必须由 migration ledger 识别为已应用。不要把包含其他 schema 版本的数据库交给当前
runner。需要重建可丢弃数据时才使用 `make local-infra-reset`。

`local-ensure-dbs` 显式设置本机 `PG*` 参数。手工运行通用 `make ensure-dbs` 或单个服务前：

```bash
source scripts/local-env.sh
make ensure-dbs
```

该脚本覆盖 canonical `DATABASE_*`、`TIMESCALE_*`、Kafka、tracing 和服务依赖地址为
loopback；不要省略它后依赖 source defaults。本流程不需要任何共享网络主机。

## 服务与可观测性

`make local-dev` 前台运行服务；`make local-start` 后台运行；`make local-stop` 停止业务
服务；`make local-infra-down` 停止基础设施。健康检查和端口清单见
[`../production-deploy-checklist.md`](../production-deploy-checklist.md)。日志进入本机 Kafka/
ELK，trace 通过本机 OTLP 进入 Jaeger。

不要直接编辑生成的 `config.local.yaml`。个人覆盖使用独立 config 路径或进程环境，并
确保输出、截图和 coverage 中没有 JWT、Telegram token、exchange key/secret、签名 URL
或 Runtime credential。

## Coverage-instrumented Runtime

```bash
cd ../strategy-service
scripts/build_strategy_runtime.sh --all --no-cache --verify dev

cd ../hushine-deploy
make local-start
```

本地 control-panel 默认使用 coverage Runtime image，产物写入 workspace
`.coverage/runtime-agent`。`LOCAL_RUNTIME_COVERAGE_IMAGE` 和
`LOCAL_RUNTIME_COVERAGE_DIR` 可显式覆盖镜像与输出目录。Runtime 容器只能收到
RuntimeChannel 地址和 sealed identity；Hosted、Self-hosted、Bare 都不能收到内部
数据库、Kafka、账户 credential、core/order 地址。

构建完必须同时检查 normal 和 coverage 镜像 label：

- strategy-service、core-service、strategy-library 和 golang-lib commit 与当前
  clean checkout 一致；
- `org.hushine.runtime.source-dirty=false`；
- dependency closure、Worker bootstrap 和镜像内 Python import verifier 通过。

仅看到 `.coverage/runtime-agent` 目录存在不算成功。需要用当前用户拥有、带 active
strategy 的 Portfolio 运行一次受跟踪 smoke：

```bash
USER_ID=<user-id> \
PORTFOLIO_ID=<portfolio-id> \
EXPECTED_INPUT_COUNT=<declared-input-count> \
COVERAGE_IMAGE=hushine/strategy-runtime:executor-coverage-dev \
bash scripts/smoke_hosted_runtime_coverage.sh \
  "$(cd .. && pwd -P)/.coverage/runtime-agent"
```

运行会创建专属 Hosted Runtime，分别执行 Preview 和两个 active Worker generation，再通过
control-panel 结束 Runtime。只有在新 Runtime 目录中出现 complete
`finalization.json`、Go covdata、Python shard，且合并后的两份报告均有命中，才能确认
本轮采样生效。脚本只清理自己的 Runtime/Session/容器，不删除用户 Portfolio。

## 停止与清理

```bash
make local-stop
make local-infra-down
```

确认没有遗留 Runtime 容器。只有确认本地数据可丢弃时才运行：

```bash
make local-infra-reset
```
