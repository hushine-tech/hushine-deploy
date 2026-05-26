# Strategy Debugger CLI Smoke

This smoke verifies that the offline strategy debugger can initialize a local
workspace, protect managed template files, load data, and replay a strategy
without a platform-connected debugger runtime.

## Local default replay

Run from the development machine:

```bash
cd /Users/xdy/Workplace/hushine/strategy-debugger-cli
python -m venv .venv
. .venv/bin/activate
pip install -e ../strategy-library
pip install -e '.[test]'
rm -rf /tmp/hushine-debug-smoke
hushine-debug init --dir /tmp/hushine-debug-smoke
cd /tmp/hushine-debug-smoke
cp strategy.py.template strategy.py
hushine-debug replay
```

Expected output contains a positive bar count:

```text
bars_processed=<positive number>
```

## Validate forbidden dependency

Run inside the smoke workspace:

```bash
cd /tmp/hushine-debug-smoke
cat > strategy.py <<'PY'
import requests

class MyStrategy:
    INPUTS = [{"market": "futures", "symbol": "BTCUSDT", "interval": "1m"}]

    def on_market_data(self, data, wallet):
        return None
PY
hushine-debug validate strategy.py
```

Expected: validation fails with `forbidden_import`.

## Platform debug package replay

1. Open the frontend and log in.
2. Open Account Management.
3. Open a backtest account.
4. Open the Local Debug tab.
5. Choose `symbol`, `interval`, `start`, and `end`.
6. Click Generate Debug Package and save the zip.
7. Import and replay:

```bash
hushine-debug init --dir /tmp/hushine-debug-package-smoke
hushine-debug import ~/Downloads/debug-package-*.zip --dir /tmp/hushine-debug-package-smoke
cd /tmp/hushine-debug-package-smoke
cp strategy.py.template strategy.py
hushine-debug replay
```

Expected output contains `bars_processed=<positive number>`.

## Cleanup

```bash
rm -rf /tmp/hushine-debug-smoke /tmp/hushine-debug-package-smoke
```
