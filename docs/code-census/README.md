# Code Census

Code Census 是 Hushine 的长期代码活性普查能力，用来辅助识别过期文档、旧架构残留、无入口代码和长期未触达路径。

版本化工具位于 hushine-deploy/scripts/audit/census；多仓源码位置必须通过 SOURCE_ROOT 明确传入。它把以下证据放进同一个 census-runs/<run-id>/：

- HTTP、gRPC、前端路由、CLI、Make、Shell、Kafka 和后台任务等静态入口。
- 数据库表级读写矩阵与静态引用。
- Elasticsearch 日志和 Jaeger trace 摘要。
- 8 个 Go module、4 个 Python 项目、部署工具、前端 contract/V8 以及 Hosted Runtime 覆盖率。
- 同一浏览器、同一标签页的前端 precise coverage。
- 保守的候选分级报告。

报告只提供证据索引，不能直接作为删除指令。任何删除都必须经过入口根源复核、用户确认和小批量回归。

## 文档入口

- [命令规则](commands.md)
- [运行前提](prerequisites.md)
- [静态扫描 Runbook](runbook-static.md)
- [Snapshot Runbook](runbook-snapshot.md)
- [人工会话 Runbook](runbook-session.md)
- [Full Runbook](runbook-full.md)
- [候选评审指南](candidate-review-guide.md)
- [Overrides 指南](overrides-guide.md)
- [排障指南](troubleshooting.md)

## 工作区布局

SOURCE_ROOT 是包含各独立仓库的目录；hushine-deploy 可以与服务仓库同级，也可以作为包含这些仓库的部署根。不要依赖操作者的当前目录。

~~~bash
SOURCE_ROOT=/absolute/path/to/hushine
DEPLOY_ROOT=$SOURCE_ROOT/hushine-deploy
~~~

输出固定落在 $SOURCE_ROOT/census-runs/<run-id>/，常用文件包括 manifest.json、summary.md、inventory/、observability/、coverage/、reachability/、candidates/ 和 evidence/。
