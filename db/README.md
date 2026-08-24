# 数据库初始化与所有权

最后核验：2026-08-25。

当前系统只支持从空数据库一次性创建当前 schema。每个 owner 仓库只保留
`0000_create_schema_migrations.sql`（需要 ledger 的服务）和
`0001_current_schema_baseline.sql`；scraper 只需要 `0001`。这些文件不是旧库升级脚本。

## 一次性部署

在标准多仓库目录的 `hushine-deploy` 根目录执行：

```bash
make ensure-dbs
```

本机 Docker 基础设施使用：

```bash
make local-infra-up
make local-ensure-dbs
make local-ensure-dbs
```

第一次执行必须创建全部数据库和对象；第二次执行必须由 migration ledger 判断为
已应用并成为无副作用操作。不要对来源不明或包含其他 schema 版本的数据库直接执行。
测试/开发环境如需采用当前 baseline，应先备份需要的数据，再重建对应数据库或 volume。

`scripts/ensure-all-dbs.sh` 按固定顺序调用各 owner：

1. core-service 创建 `portfolio`
2. core-service order 模块创建 `order`
3. control-panel-service 创建 `control_panel`
4. scraper 创建当前需要的 `{exchange}_{year}` 年库

连接信息由各服务当前配置提供。本机目标显式使用标准 `PGHOST`、`PGPORT`、
`PGUSER`、`PGPASSWORD` 和 `PGDATABASE_ADMIN`；order 模块会把这些值映射到当前
`ORDER_DATABASE_*` 配置。

## Schema 所有权

| 数据库 | Owner | Baseline | 主要对象 |
|---|---|---|---|
| `portfolio` | core-service | `internal/storage/migrations/0001_current_schema_baseline.sql` | Portfolio、Venue、Strategy、Session、wallet snapshot、notification、reconciliation、Spot risk、Indicator V2、strategy leverage launch/admission/facts/outbox |
| `order` | core-service order 模块 | `internal/order/storage/migrations/0001_current_schema_baseline.sql` | intent、attempt、order、fill、lifecycle、recovery、Spot close/admission |
| `control_panel` | control-panel-service | `internal/storage/migrations/0001_current_schema_baseline.sql` | Runtime registry/credential/channel/command、market-data stream/request/lease、Session subscription/cleanup outbox |
| `{exchange}_{year}` | scraper | `internal/storage/migrations/0001_current_schema_baseline.sql` | TimescaleDB 扩展和 migration ledger；symbol/interval 表在首次写入时按当前命名创建 |

数据库之间不复制 owner 状态：交易和钱包事实属于 core-service，Runtime 与
market-data 控制状态属于 control-panel-service，行情数据属于 scraper 年库。

## 手工审阅 bundle

```bash
make db-schema-bundle
```

该命令从 owner 仓库的当前 baseline 重新生成：

- `db/generated/portfolio.sql`
- `db/generated/order.sql`
- `db/generated/control_panel.sql`
- `db/generated/market_data_year.sql`
- `db/generated/00_create_databases.psql`

bundle 用于 fresh bootstrap 审阅或受控手工执行，不能取代 owner migration runner。
修改 baseline 后必须重新生成，并确保生成目录无差异。

## 验证

```bash
cd core-service
go test ./cmd/ensure-portfolio-db ./cmd/ensure-order-db \
  ./internal/storage/migrations ./internal/order/storage/migrations -count=1

cd ../control-panel-service
go test ./internal/storage -count=1

cd ../scraper
go test ./internal/storage -count=1
```

本地 fresh-bootstrap 验收还必须确认：

- `portfolio`、`order`、`control_panel` 的 ledger 各有 `0000_create_schema_migrations.sql` 和 `0001_current_schema_baseline.sql` 两条记录；scraper 年库只有 `0001_current_schema_baseline.sql` 一条记录
- 当前 ledger 只记录 `filename` 与 `applied_at`，不声明不存在的 checksum 校验能力
- `portfolio` 同时具有 Indicator V2 和逐 target leverage 对象
- `order` 同时具有 Spot exact route、close 和 recovery 对象
- `control_panel` 具有 runtime Session cleanup outbox
- scraper 动态表按 `{market}_klines_{symbol}_{interval}` 或当前数据类型命名
- 第二次运行不重建表、不重置 sequence、不修改业务数据

任何“已有旧列则转换”“找不到新表则读取旧表”或旧 migration 文件都不属于当前部署
流程；需要保留的业务数据必须走单独、显式的数据迁移项目，不能塞回启动路径。
