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

`unit-coverage`、`full` 和 `session-stop` 会把 Go cover profile、Python
coverage JSON 以及保留浏览器产生的 `coverage/frontend-precise.json`
标准化到 `evidence/coverage.jsonl`。文件 subject 使用相对
`SOURCE_ROOT` 的路径，函数 subject 使用
`<workspace-relative-file>::<function>`。只有实际执行次数大于零的记录
会标记对应文件、函数和同文件静态入口为 active；零覆盖本身不构成删除
证据。

如果 session-start 登记了外部浏览器 owner，session-stop 要求 owner 先
完成 precise coverage 归一化。缺失、绑定不匹配或不含工作区源文件的
`frontend-precise.json` 会使收集失败，避免用不完整前端覆盖率生成删除
候选。

关闭本地插桩服务时默认给每个服务 10 秒 TERM 收尾时间：

~~~bash
CODE_CENSUS_STOP_TIMEOUT_SECONDS=10 \
  scripts/audit/census/start_instrumented_stack.sh \
  --source-root "$SOURCE_ROOT" --stop "$RUN_ID"
~~~

脚本使用单调时钟轮询，在期限结束后只对仍存活的进程树发送 KILL，并将
每个服务的 `graceful`、`forced` 或 `already-stopped` 结果写到
`coverage/instrumented-stack-stop.json`。超时只接受 `(0, 600]` 秒。
