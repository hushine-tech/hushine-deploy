# 候选评审指南

版本化工具位于 hushine-deploy/scripts/audit/census。候选分级只是证据排序，不是删除结论。

建议依次检查：

1. inventory/static-entrypoints.json：HTTP、gRPC、frontend route、CLI、Kafka、后台任务入口。
2. observability/endpoint-activity.json：最近窗口是否存在 trace、log 或 event。
3. coverage/：自动与人工场景是否触达；注意低频恢复和失败路径。
4. reachability/static-references.json：import、proto、SQL 和脚本引用。
5. 当前 Notion 架构/用户手册以及版本化部署文档；归档设计只能作历史依据。
6. 让用户确认功能保留或删除，再记录决定。

每个删除候选至少记录 reviewer、candidate、入口复核、observability、coverage、决定、理由和回归命令。

删除约束：

- 小批量删除，每批运行相关单测、契约和服务级测试。
- 不把业务代码、迁移、文档和部署脚本混在一个不可复核的批次。
- never-delete-by-coverage 只能通过独立兼容性决定处理。
- migration、proto、生成代码、测试 fixture、安全兜底和灾难恢复路径不能仅凭覆盖率删除。
- 覆盖率为零只代表本次场景未触达，不代表功能无用。
