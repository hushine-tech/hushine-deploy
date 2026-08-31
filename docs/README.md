# Hushine 文档归属

当前用户手册、系统架构和基础运维文档的唯一内容源是同级独立仓库
`hushine-docs`，用户通过 Portal 左侧底部的 **Documentation** 入口阅读。该页面为只读：
Markdown 在 `hushine-docs` 中评审和提交，部署流程构建不可变发布包后由
`quant-handler` 按登录用户权限提供。

```text
hushine-docs Markdown
  -> make docs-build
  -> verified releases/<docs_commit>
  -> atomic current symlink
  -> quant-handler /api/docs/*
  -> quant-frontend /docs
```

本仓库的文档边界如下：

- `docs/superpowers/`、`openspec/`、日期化审计与测试报告保存设计决策和验收证据，不是当前用户操作入口。
- `db/README.md` 和各服务 migration 继续是数据库 schema 的权威来源；文档中心只提供面向读者的解释。
- `README.md`、脚本和 Make target 继续定义发布、启动和验收动作。
- 仍保留的旧用户手册/架构/运维 Markdown 仅用于迁移核对，不再作为当前内容源；确认对应页面已迁移并通过 Portal smoke 后，按独立删除提交清理。

本地生成并发布文档：

```bash
make local-docs
```

发布失败不会切换 `current`。文档包缺失或校验失败时，只有 `/api/docs/*` 返回
`DOCS_UNAVAILABLE`，健康检查和交易业务接口继续可用。
