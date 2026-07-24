# Full Runbook

版本化工具位于 hushine-deploy/scripts/audit/census。Full 模式执行静态入口、DB 矩阵、Jaeger/Elasticsearch snapshot、8 个 Go module、4 个 Python 项目、部署工具和前端 contract/V8 覆盖率，再生成候选分级。

~~~bash
SOURCE_ROOT=/absolute/path/to/hushine
RUN_ID=full-$(date +%Y%m%d-%H%M%S)
make -C "$SOURCE_ROOT/hushine-deploy" code-census-full SOURCE_ROOT="$SOURCE_ROOT" RUN_ID="$RUN_ID"
~~~

注意：

- Full 耗时较长，observability 不可用时直接失败。
- 任何单测或契约失败都会让覆盖率集合失败，并保留各 subject 的 test-output.txt。
- Full 报告仍不是删除指令。
- 前端真实页面 precise coverage 属于 session 流程，不由 Full 另起浏览器采集。

适合在大重构前后、主要产品阶段收尾和覆盖率驱动的代码瘦身评审前运行。
