# Code Census 命令规则

版本化入口位于 hushine-deploy/scripts/audit/census。所有 Make 命令都从 hushine-deploy 执行，并显式传入包含各仓库的绝对 SOURCE_ROOT。

| Command | Purpose | Requires Jaeger/ES |
| --- | --- | --- |
| make code-census-static SOURCE_ROOT=/absolute/source RUN_ID=<id> | 静态入口、DB 矩阵、引用关系 | No |
| make code-census-unit-coverage SOURCE_ROOT=/absolute/source RUN_ID=<id> | 8 Go、4 Python、部署工具、前端 contract/V8 | No |
| make code-census-snapshot SOURCE_ROOT=/absolute/source RUN_ID=<id> | 静态证据和最近 observability 窗口 | Yes |
| make code-census-session-start SOURCE_ROOT=/absolute/source RUN_ID=<id> | 生成运行时插桩脚本并登记外部浏览器 owner | Yes |
| make code-census-session-stop SOURCE_ROOT=/absolute/source RUN_ID=<id> | 汇总 Runtime、前端和 observability 证据 | Yes |
| make code-census-full SOURCE_ROOT=/absolute/source RUN_ID=<id> | snapshot 加全部单元/契约覆盖率 | Yes |

示例：

~~~bash
SOURCE_ROOT=/absolute/path/to/hushine
make -C "$SOURCE_ROOT/hushine-deploy" code-census-static SOURCE_ROOT="$SOURCE_ROOT" RUN_ID=static-20260723
make -C "$SOURCE_ROOT/hushine-deploy" code-census-unit-coverage SOURCE_ROOT="$SOURCE_ROOT" RUN_ID=unit-20260723
~~~

session-stop 必须复用 session-start 的 RUN_ID。除 static 和 unit-coverage 外，Jaeger/Elasticsearch precheck 失败是阻断，不是自动降级。
