# Code Census

Code Census 是 Hushine 的长期代码活性普查能力，用来辅助持续清理过期文档、旧架构残留、无入口代码和长期未触达路径。

它不是一次性删除工具，也不是覆盖率百分比报表。它的核心用途是把以下证据放到同一个 run 目录里，供人工复核：

- 静态入口清单：HTTP、gRPC、frontend route、CLI、Makefile、shell、Kafka topic、background worker hint。
- DB 表级读写矩阵。
- Jaeger trace 和 Elasticsearch / Elemental 日志证据。
- Go、Python、前端浏览器覆盖率辅助证据。
- 候选分级报告。

报告只提供证据索引，不能直接作为删除指令。任何删除都必须经过入口根源复核、人工确认和小批量验证。

## 文档入口

- [命令规则](commands.md)
- [运行前提](prerequisites.md)
- [静态扫描 Runbook](runbook-static.md)
- [Snapshot Runbook](runbook-snapshot.md)
- [人工会话 Runbook](runbook-session.md)
- [Full Runbook](runbook-full.md)
- [候选评审指南](candidate-review-guide.md)
- [Overrides 指南](overrides-guide.md)
- [排障指南](troubleshooting.md)

## 输出目录

每次运行都会在根工作区生成：

```bash
/Users/xdy/Workplace/hushine/census-runs/<run-id>/
```

常用文件：

- `manifest.json`
- `summary.md`
- `inventory/static-entrypoints.json`
- `inventory/db-table-matrix.json`
- `observability/precheck.json`
- `observability/logs-summary.json`
- `observability/traces-summary.json`
- `coverage/unit-coverage-summary.json`
- `reachability/static-references.json`
- `candidates/all-candidates.json`
- `evidence/*.jsonl`

