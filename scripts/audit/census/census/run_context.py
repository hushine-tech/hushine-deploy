from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
import json
import os


@dataclass(frozen=True)
class RunContext:
    workspace: Path
    run_id: str
    run_dir: Path
    mode: str
    started_at: str

    @classmethod
    def create(cls, workspace: Path, output_root: str, mode: str, run_id: str | None) -> "RunContext":
        started = datetime.now(timezone.utc)
        rid = run_id or os.getenv("RUN_ID") or started.strftime("%Y%m%d-%H%M%S")
        run_dir = workspace / output_root / rid
        for name in ["inventory", "observability", "coverage", "reachability", "candidates", "evidence"]:
            (run_dir / name).mkdir(parents=True, exist_ok=True)
        ctx = cls(workspace=workspace, run_id=rid, run_dir=run_dir, mode=mode, started_at=started.isoformat())
        ctx.write_manifest()
        return ctx

    def write_manifest(self) -> None:
        manifest = {
            "run_id": self.run_id,
            "mode": self.mode,
            "workspace": str(self.workspace),
            "started_at": self.started_at,
            "pid": os.getpid(),
        }
        (self.run_dir / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
