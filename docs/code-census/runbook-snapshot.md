# Snapshot Runbook

版本化工具位于 hushine-deploy/scripts/audit/census。Snapshot 从最近 observability 窗口抽取真实运行证据。

~~~bash
SOURCE_ROOT=/absolute/path/to/hushine
RUN_ID=snapshot-$(date +%Y%m%d-%H%M%S)
make -C "$SOURCE_ROOT/hushine-deploy" code-census-snapshot SOURCE_ROOT="$SOURCE_ROOT" RUN_ID="$RUN_ID"
~~~

必须满足 Elasticsearch 与 Jaeger API 可访问、日志含 trace_id/span_id、Jaeger 可查到 Hushine 服务 trace。

重点检查 observability/precheck.json、logs-summary.json、traces-summary.json、endpoint-activity.json、candidates/all-candidates.json 和 summary.md。FAILED_PRECHECK 表示本次 snapshot 失败，不是 static 降级。
