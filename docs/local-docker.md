# Local Docker Environment

目标：把开发环境从默认共享依赖 `192.168.88.10` 切到本机 Docker，业务服务仍从源码本机运行。

## 组件

- `timescaledb`：本机 `127.0.0.1:5432`
- `kafka`：本机 `127.0.0.1:9092`
- `elasticsearch`：本机 `http://127.0.0.1:9200`
- `kibana`：本机 `http://127.0.0.1:5601`
- `jaeger`：UI `http://127.0.0.1:16686`，OTLP HTTP `http://127.0.0.1:4318`

## 启动

```bash
IMAGE_TAG=dev make runtime-image
make local-start
```

`runtime-image` 同时构建普通与 coverage runtime。`local-start` 会先执行
`local-bootstrap`：从各服务的受跟踪配置确定性生成权限为 `0600` 的
`config.local.yaml`，启动 Docker 基础设施、等待 TimescaleDB、创建数据库并应用
migrations。生成器会把 DB/Kafka/Jaeger 切到本机，并关闭本地 RuntimeChannel TLS；
不会向 runtime 注入 DB、Kafka、core-service 或 order.v1 地址。

本地 control-panel 默认开启 hosted runtime 覆盖率收集：

- 镜像：`hushine/strategy-runtime:executor-coverage-dev`
- 输出目录：工作区 `.coverage/runtime-agent`
- 可通过 `LOCAL_RUNTIME_COVERAGE_IMAGE` 与
  `LOCAL_RUNTIME_COVERAGE_DIR` 覆盖

前台调试：

```bash
make local-dev
```

停止：

```bash
make local-stop
make local-infra-down
```

## Runtime smoke

本机应用服务启动后，runtime 统一从 control-panel 管理：

```bash
USER_ID=<users.id> make smoke-hosted-runtime
```

自定义 runtime 只走 RuntimeChannel，不需要也不应该拿到
core-service / order.v1 / Kafka / 数据库地址：

```bash
CREDENTIAL_FILE=$HOME/.hushine/runtime.cred \
RUNTIME_CHANNEL_ADDR=host.docker.internal:50055 \
make smoke-self-hosted-runtime
```

远端 Docker 主机模拟用户机器时：

```bash
CREDENTIAL_FILE=$HOME/.hushine/runtime.cred \
REMOTE_HOST=<docker-host> \
REMOTE_USER=<ssh-user> \
RUNTIME_CHANNEL_ADDR=$MAC_LAN_IP:50055 \
make smoke-self-hosted-runtime
```

清空本地 Docker 数据：

```bash
make local-infra-reset
```

只启动基础设施并建表：

```bash
make local-bootstrap
```

## 手动运行单个服务

```bash
make local-bootstrap

cd core-service
make dev CONFIG=./config.local.yaml

cd ../control-panel-service
RUNTIME_COVERAGE_ENABLED=true \
RUNTIME_COVERAGE_OUTPUT_DIR=/absolute/path/to/.coverage/runtime-agent \
RUNTIME_COVERAGE_IMAGE=hushine/strategy-runtime:executor-coverage-dev \
make dev CONFIG=./config.local.yaml

cd ../gateway/quant-handler
make dev CONFIG=./config.local.yaml

cd ../../scraper
make dev CONFIG=./config.local.yaml LOG_CONFIG=./log-config.local.json
```

## 注意

- 不要直接改默认 `config.yaml`。`make local-configs`/`local-bootstrap` 会覆盖生成的
  `config.local.yaml` 与 `scraper/log-config.local.json`；需要个人定制时使用另一条
  配置路径或环境变量。
- `source scripts/local-env.sh` 适合跑 `make ensure-dbs` 等命令；业务服务建议使用 `CONFIG=./config.local.yaml`，因为日志 Kafka 和 tracing endpoint 在配置文件里。
- 如果本机设置了 `http_proxy` / `https_proxy`，本地启动目标会自动设置 `NO_PROXY=127.0.0.1,localhost,::1`，避免 gRPC / OTLP / HTTP 调用本机服务时被代理劫持。
- 当前 scraper 本地配置保留 control-plane 模式，静态 forward collector 仍关闭，避免本机 Kafka/DB 被无需求流量打满。
