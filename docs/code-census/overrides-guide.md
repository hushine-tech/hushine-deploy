# Overrides 指南

Overrides 文件位于：

```bash
/Users/xdy/Workplace/hushine/scripts/audit/census/overrides.yaml
```

第一版主要支持 `never_delete_by_coverage`：

```yaml
classifications:
  never_delete_by_coverage:
    - path: "**/migrations/"
      reason: "迁移文件是环境再现依据"
```

适合放入 override 的路径：

- 数据库迁移。
- proto 契约。
- generated code。
- 测试 fixture。
- 安全兜底路径。
- 灾难恢复脚本。
- 明确低频但仍需保留的运维命令。

不建议放入 override 的内容：

- 只是“可能还有用”的普通旧代码。
- 没有 owner 的旧文档。
- 无入口、无 trace、无引用且没有业务解释的兼容层。

这类内容应该进入候选评审，而不是永久保护。

