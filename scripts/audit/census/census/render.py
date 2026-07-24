from .writer import write_markdown


def render_summary(ctx, cfg, classification: dict) -> None:
    buckets = classification.get("buckets", {})
    lines = [
        "# Code Census Summary",
        "",
        f"- Run ID: `{ctx.run_id}`",
        f"- Mode: `{ctx.mode}`",
        f"- Started At: `{ctx.started_at}`",
        f"- static-only: `{str(classification.get('static_only', False)).lower()}`",
        "",
        "## 重要边界",
        "",
        "- 这份报告是 evidence index，不是删除指令。",
        "- 每一个 delete-candidate 都必须做入口根源可达性复核，并经过人工确认。",
        "- static-only 运行不能产生高置信删除结论。",
        "- migration、proto、generated code、测试 fixture、安全兜底路径不能只按覆盖率删除。",
        "",
        "## Candidate Buckets",
        "",
    ]
    for bucket in ["active", "cold-valid", "suspicious-legacy", "delete-candidate", "never-delete-by-coverage", "unknown"]:
        lines.append(f"- `{bucket}`: {buckets.get(bucket, 0)}")
    lines.extend(
        [
            "",
            "## 输出位置",
            "",
            "- `inventory/`: 静态入口、DB 表级读写矩阵。",
            "- `observability/`: Jaeger / Elasticsearch precheck 和窗口摘要。",
            "- `coverage/`: 单测、运行时、前端浏览器覆盖率辅助证据。",
            "- `reachability/`: 静态引用和候选不可达文件。",
            "- `candidates/`: 候选分级。",
            "- `evidence/`: JSONL 原始证据流。",
        ]
    )
    write_markdown(ctx.run_dir / "summary.md", "\n".join(lines))


def render_manual_checklist(ctx, cfg) -> None:
    service_names = ", ".join(service["name"] for service in cfg.services)
    text = f"""
# Code Census Manual Scenarios

Run ID: `{ctx.run_id}`

## 本次需要记录

- 测试人：
- 起止时间：
- 账号 / user_id：
- portfolio_id：
- runtime_id：
- session_id：
- trace_id 样例：
- 页面路径：
- 操作场景：
- 预期结果：
- 实际结果：
- 备注：

## 纳入服务

{service_names}

## 场景记录

| 时间 | 页面/API | 操作 | 关键 ID | trace_id | 结果 |
| --- | --- | --- | --- | --- | --- |
| | | | | | |
"""
    write_markdown(ctx.run_dir / "manual-scenarios.md", text)
