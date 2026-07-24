from dataclasses import dataclass
from pathlib import Path
import os

import yaml


@dataclass(frozen=True)
class CensusConfig:
    raw: dict
    config_path: Path

    @property
    def output_root(self) -> str:
        return self.raw.get("output", {}).get("root", "census-runs")

    @property
    def services(self) -> list[dict]:
        return list(self.raw.get("services", []))

    @property
    def observability(self) -> dict:
        data = dict(self.raw.get("observability", {}))
        if os.getenv("CODE_CENSUS_ES_URL"):
            data["elasticsearch_url"] = os.environ["CODE_CENSUS_ES_URL"]
        if os.getenv("CODE_CENSUS_JAEGER_URL"):
            data["jaeger_url"] = os.environ["CODE_CENSUS_JAEGER_URL"]
        return data

    @property
    def hosted_runtime_coverage(self) -> dict:
        data = dict(self.raw.get("hosted_runtime_coverage", {}))
        data.setdefault("stop_timeout_seconds", 10)
        return data

    @property
    def protected_paths(self) -> list[str]:
        return list(self.raw.get("protected_paths", []))


def load_config(path: Path) -> CensusConfig:
    with path.open("r", encoding="utf-8") as fh:
        data = yaml.safe_load(fh) or {}
    config = CensusConfig(raw=data, config_path=path)
    stop_timeout = config.hosted_runtime_coverage["stop_timeout_seconds"]
    if isinstance(stop_timeout, bool) or not isinstance(stop_timeout, int) or stop_timeout <= 0:
        raise ValueError("hosted_runtime_coverage.stop_timeout_seconds must be a positive integer")
    return config
