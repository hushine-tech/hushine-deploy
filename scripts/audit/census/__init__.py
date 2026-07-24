from pathlib import Path
import sys

TOOL_ROOT = Path(__file__).resolve().parent
if str(TOOL_ROOT) not in sys.path:
    sys.path.insert(0, str(TOOL_ROOT))

# Pytest imports this directory as the outer ``census`` package when it walks
# from the repository root.  Keep the command-line layout (the implementation
# lives in ``census/census``) importable in that mode as well.
IMPLEMENTATION_ROOT = str(TOOL_ROOT / "census")
if IMPLEMENTATION_ROOT not in __path__:
    __path__.insert(0, IMPLEMENTATION_ROOT)
