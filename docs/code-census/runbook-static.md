# Static Runbook

版本化工具位于 hushine-deploy/scripts/audit/census。静态模式用于快速生成入口、表级读写和引用清单，不依赖 Jaeger/Elasticsearch。

~~~bash
SOURCE_ROOT=/absolute/path/to/hushine
RUN_ID=static-$(date +%Y%m%d-%H%M%S)
make -C "$SOURCE_ROOT/hushine-deploy" code-census-static SOURCE_ROOT="$SOURCE_ROOT" RUN_ID="$RUN_ID"
~~~

重点检查 inventory/static-entrypoints.json、inventory/db-table-matrix.json、reachability/static-references.json 和 summary.md。

静态结果只能说明代码形态上是否存在入口或引用迹象，不能证明代码真实活跃，也不能作为高置信删除依据。它适合全局盘点、人工测试清单准备和查找旧脚本/Make target/前端 route。
