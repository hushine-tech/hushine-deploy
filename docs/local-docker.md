# Local Docker Environment

目标：把开发环境从 `192.168.66.13` 切到本机 Docker，业务服务仍从源码本机运行。

## 组件

- `timescaledb`：本机 `127.0.0.1:5432`
- `kafka`：本机 `127.0.0.1:9092`
- `elasticsearch`：本机 `http://127.0.0.1:9200`
- `kibana`：本机 `http://127.0.0.1:5601`
- `jaeger`：UI `http://127.0.0.1:16686`，OTLP HTTP `http://127.0.0.1:4318`

## 启动

```bash
make local-start
```

`local-start` 会先执行 `local-bootstrap`：启动 Docker 基础设施、等待 TimescaleDB、创建数据库并应用 migrations。

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
USER_ID=<account.users.id> make smoke-hosted-runtime
```

自定义 runtime 只走 RuntimeChannel，不需要也不应该拿到
account-service / order.v1 / Kafka / 数据库地址：

```bash
CREDENTIAL_FILE=$HOME/.hushine/runtime.cred \
CONTROL_PANEL_ADDR=host.docker.internal:50054 \
make smoke-self-hosted-runtime
```

远端 Docker 主机模拟用户机器时，把 `CONTROL_PANEL_ADDR` 换成本机 Mac
在局域网中的可达地址，并设置 `REMOTE_HOST` / `REMOTE_USER`。

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

cd account-service
make dev CONFIG=./config.local.yaml

cd ../strategy-service
make dev CONFIG=./config.local.yaml

cd ../gateway/quant-handler
make dev CONFIG=./config.local.yaml

cd ../../scraper
make dev CONFIG=./config.local.yaml LOG_CONFIG=./log-config.local.json
```

## 注意

- 不要直接改默认 `config.yaml`，默认配置仍保留远端开发机。
- `source scripts/local-env.sh` 适合跑 `make ensure-dbs` 等命令；业务服务建议使用 `CONFIG=./config.local.yaml`，因为日志 Kafka 和 tracing endpoint 在配置文件里。
- 如果本机设置了 `http_proxy` / `https_proxy`，本地启动目标会自动设置 `NO_PROXY=127.0.0.1,localhost,::1`，避免 gRPC / OTLP / HTTP 调用本机服务时被代理劫持。
- 当前 scraper 本地配置保留 control-plane 模式，静态 forward collector 仍关闭，避免本机 Kafka/DB 被无需求流量打满。
