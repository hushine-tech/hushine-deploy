#!/usr/bin/env python3
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))

from census.cli import main  # noqa: E402 - bootstrap the adjacent package first


if __name__ == "__main__":
    raise SystemExit(main())
