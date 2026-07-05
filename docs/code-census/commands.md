# Code Census 命令规则

所有命令从根工作区执行：

```bash
cd /Users/xdy/Workplace/hushine
```

| Command | Purpose | Requires Jaeger/ES | Output |
| --- | --- | --- | --- |
| `make code-census-static` | 静态入口、DB 表级矩阵、引用关系 | No | `census-runs/<run-id>/inventory/` |
| `make code-census-snapshot` | 静态扫描 + 最近窗口 observability 摘要 | Yes | `observability/`, `candidates/`, `summary.md` |
| `make code-census-session-start` | 开始人工测试采集会话 | Yes | `manual-scenarios.md`, collectors metadata |
| `make code-census-session-stop RUN_ID=<run-id>` | 结束人工测试采集会话并汇总 | Yes | session coverage + observability |
| `make code-census-full` | snapshot + 单测覆盖率 + 候选分级 | Yes | full run report |

## RUN_ID

默认 `RUN_ID` 使用当前 UTC 时间生成。需要固定输出目录时使用：

```bash
RUN_ID=manual-20260703 make code-census-static
```

结束人工会话必须指定同一个 `RUN_ID`：

```bash
make code-census-session-stop RUN_ID=manual-20260703
```

## Observability 强约束

除 `static` 外，所有模式都要求 Jaeger 和 Elasticsearch 可访问、可查询。不可用时命令失败，并在：

```bash
census-runs/<run-id>/observability/precheck.json
```

写入：

```text
FAILED_PRECHECK: observability unavailable
```

这不是降级成功，而是阻断信号。

