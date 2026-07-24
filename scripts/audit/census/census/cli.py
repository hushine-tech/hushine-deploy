from pathlib import Path
import argparse
import sys

from .candidates import classify_candidates
from .config import load_config
from .coverage import CoverageCollectionFailed, collect_unit_coverage, start_session_collectors, stop_session_collectors
from .db_matrix import collect_db_matrix
from .handler_reachability import collect_handler_reachability
from .observability import ObservabilityUnavailable, collect_observability_snapshot, require_observability
from .render import render_manual_checklist, render_summary
from .run_context import RunContext
from .static_inventory import collect_static_inventory


TOOL_ROOT = Path(__file__).resolve().parents[4]
CONFIG_PATH = TOOL_ROOT / "scripts/audit/census/config.yaml"


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="code-census")
    parser.add_argument(
        "mode",
        choices=[
            "static",
            "snapshot",
            "unit-coverage",
            "session-start",
            "session-stop",
            "full",
        ],
    )
    parser.add_argument("--config", default=str(CONFIG_PATH))
    parser.add_argument("--source-root")
    parser.add_argument("--run-id")
    parser.add_argument("--window-minutes", type=int)
    args = parser.parse_args(argv)

    source_root = Path(args.source_root) if args.source_root else TOOL_ROOT
    if not source_root.is_absolute():
        parser.error("--source-root must be absolute")
    if not source_root.is_dir():
        parser.error(f"--source-root directory does not exist: {source_root}")
    source_root = source_root.resolve()

    cfg = load_config(Path(args.config))
    ctx = RunContext.create(source_root, cfg.output_root, args.mode, args.run_id)

    try:
        collect_static_inventory(ctx, cfg)
        collect_db_matrix(ctx, cfg)
        collect_handler_reachability(ctx, cfg)

        if args.mode == "static":
            render_summary(ctx, cfg, classification=classify_candidates(ctx, cfg, static_only=True))
            print(f"code census run: {ctx.run_dir}")
            return 0

        if args.mode == "unit-coverage":
            collect_unit_coverage(ctx, cfg)
            render_summary(
                ctx,
                cfg,
                classification=classify_candidates(ctx, cfg, static_only=False),
            )
            print(f"code census run: {ctx.run_dir}")
            return 0

        require_observability(ctx, cfg)

        if args.mode in ["snapshot", "full"]:
            collect_observability_snapshot(ctx, cfg, args.window_minutes)
        if args.mode == "session-start":
            render_manual_checklist(ctx, cfg)
            start_session_collectors(ctx, cfg)
        if args.mode == "session-stop":
            stop_session_collectors(ctx, cfg)
            collect_observability_snapshot(ctx, cfg, args.window_minutes)
        if args.mode == "full":
            collect_unit_coverage(ctx, cfg)

        render_summary(ctx, cfg, classification=classify_candidates(ctx, cfg, static_only=False))
        print(f"code census run: {ctx.run_dir}")
        return 0
    except (ObservabilityUnavailable, CoverageCollectionFailed) as exc:
        print(str(exc), file=sys.stderr)
        return 1
