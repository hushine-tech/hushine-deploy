# Snapshot Runbook

Snapshot 模式用于从最近 observability 窗口抽取真实运行证据。

```bash
cd /Users/xdy/Workplace/hushine
RUN_ID=snapshot-$(date +%Y%m%d-%H%M%S) make code-census-snapshot
```

必须满足：

- Elasticsearch 可访问。
- Jaeger API 可访问。
- 日志中有 `trace_id` / `span_id`。
- Jaeger 能查询到 Hushine 服务 trace。

重点看：

- `observability/precheck.json`
- `observability/logs-summary.json`
- `observability/traces-summary.json`
- `observability/endpoint-activity.json`
- `candidates/all-candidates.json`
- `summary.md`

如果 `precheck.json` 出现 `FAILED_PRECHECK: observability unavailable`，本次 snapshot 失败，不要把它当成 static 降级结果。

