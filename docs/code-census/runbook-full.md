# Full Runbook

Full 模式用于周期性较完整体检。它会执行：

- 静态入口扫描。
- DB 表级读写矩阵。
- Jaeger / Elasticsearch precheck。
- Observability snapshot。
- Go / Python 单测覆盖率辅助采集。
- 候选分级。

运行：

```bash
cd /Users/xdy/Workplace/hushine
RUN_ID=full-$(date +%Y%m%d-%H%M%S) make code-census-full
```

注意：

- Full 模式耗时较长。
- Jaeger / Elasticsearch 不可用时直接失败。
- 单测覆盖率失败会记录在 `coverage/unit-coverage-summary.json`，需要人工判断是环境问题还是真实测试失败。
- Full 报告仍然不是删除指令。

适合频率：

- 大重构前后。
- 每个主要产品阶段收尾。
- 周期性代码瘦身评审。

