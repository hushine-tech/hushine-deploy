# 候选评审指南

候选分级只是证据排序，不是删除结论。

建议评审顺序：

1. 看 `inventory/static-entrypoints.json`，确认是否存在 HTTP / gRPC / frontend route / CLI / Kafka / background worker 入口。
2. 看 `observability/endpoint-activity.json`，确认最近窗口是否有 trace / log / event 证据。
3. 看 `coverage/`，确认人工或自动场景是否触达。
4. 看 `reachability/static-references.json`，确认是否仍被 import / proto / SQL 引用。
5. 查 OpenSpec、部署脚本、运维文档，确认是否是低频路径、安全兜底或恢复路径。
6. 记录人工结论。

每个删除候选至少记录：

```text
reviewer:
candidate:
entry-root checked:
observability checked:
coverage checked:
decision:
reason:
follow-up command:
```

删除规则：

- 小批量删除。
- 每批删除后运行相关单测和服务级测试。
- 不在同一批混合删除业务代码、迁移、文档和部署脚本。
- `never-delete-by-coverage` 桶只能通过独立人工变更处理。

