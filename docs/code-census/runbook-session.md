# Session Runbook

Session 模式用于人工页面测试期间收集证据。典型流程：

1. 启动服务和前端。
2. 确认 Jaeger / Elasticsearch 可用。
3. 可选：启动 Chrome CDP。
4. 开始会话。
5. 人工在页面上覆盖核心流程。
6. 停止会话并汇总证据。

开始：

```bash
cd /Users/xdy/Workplace/hushine
CODE_CENSUS_CHROME_DEBUG_URL=http://127.0.0.1:9222 \
RUN_ID=manual-$(date +%Y%m%d-%H%M%S) \
make code-census-session-start
```

工具会生成：

```bash
census-runs/<run-id>/manual-scenarios.md
```

人工测试时至少记录：

- 测试人
- 页面/API
- portfolio_id
- runtime_id
- session_id
- trace_id 样例
- 操作结果
- 备注

结束：

```bash
make code-census-session-stop RUN_ID=<run-id>
```

重点看：

- `manual-scenarios.md`
- `coverage/session-coverage-summary.json`
- `observability/endpoint-activity.json`
- `summary.md`
