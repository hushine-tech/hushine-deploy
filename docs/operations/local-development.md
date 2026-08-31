# 本地开发文档迁移说明

当前版本的本地开发手册已迁移到独立 `hushine-docs` 仓库：

```text
hushine-docs/content/operations/local-development.md
```

启动 Portal 后，从左侧底部进入 **Documentation → 基础运维 → 本地开发** 阅读。
该页面与当前文档发布包、服务 commit 和 Runtime 镜像事实绑定；本文件不再重复维护操作步骤，避免两份说明继续漂移。

本仓库仍负责执行入口：

```bash
make local-docs
make local-bootstrap
make local-dev
make local-start
make local-stop
```

其中 `make local-docs` 只接受完整的 `hushine-docs` Git 仓库，构建后验证正文、搜索索引和资源哈希，再原子切换 `.generated/docs/current`。数据库 schema 的权威说明仍是 `db/README.md` 与各服务 migration。
