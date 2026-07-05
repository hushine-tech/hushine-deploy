# Static Runbook

静态模式用于快速生成入口和引用清单，不依赖 Jaeger / Elasticsearch。

```bash
cd /Users/xdy/Workplace/hushine
RUN_ID=static-$(date +%Y%m%d-%H%M%S) make code-census-static
```

重点看：

- `inventory/static-entrypoints.json`
- `inventory/db-table-matrix.json`
- `reachability/static-references.json`
- `summary.md`

静态结果只能说明“代码形态上是否有入口或引用迹象”。它不能证明代码真实活跃，也不能作为高置信删除依据。

适用场景：

- 做一次快速全局盘点。
- 准备人工测试清单。
- 查看表级 DB 读写分布。
- 查旧脚本、旧 Makefile target、旧前端 route。

