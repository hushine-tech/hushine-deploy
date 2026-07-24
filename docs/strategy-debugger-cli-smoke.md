# Strategy Debugger CLI Smoke

最后核验：2026-07-23。

本检查验证用户本地 debugger 能在不连接平台、RuntimeChannel、数据库或 Kafka
的情况下完成初始化、导入 package v2、校验策略并离线回放。平台连接的
bare/debugger runtime 是内部受控能力，不是用户调试的前置条件。

## 1. 默认离线回放

从 `strategy-debugger-cli` 仓库执行支持的 uv bootstrap：

```bash
rm -rf /tmp/hushine-debug-smoke
uv run --no-project --python 3.13 python init.py \
  --workspace /tmp/hushine-debug-smoke
cd /tmp/hushine-debug-smoke
.venv/bin/python -I -m hushine_debugger.cli profile --json
.venv/bin/hushine-debug replay
```

Windows PowerShell 使用：

```powershell
uv run --no-project --python 3.13 python init.py `
  --workspace "$HOME\hushine-debug-smoke"
cd "$HOME\hushine-debug-smoke"
& .\.venv\Scripts\python.exe -I -m hushine_debugger.cli profile --json
.\.venv\Scripts\hushine-debug replay
```

成功标准：profile 校验为成功，回放输出 `Backtest completed`、正数
`Bars processed`，并打印 fill、PnL 与 return 汇总。`init.py` 会用 frozen lock
建立 staging venv、验证安装闭包后原子替换目标 `.venv`；失败时不能破坏原工作区。

## 2. 禁止依赖校验

在 smoke 工作区把 `strategy.py` 临时替换为：

```python
import requests


class MyStrategy:
    INPUTS = [
        {
            "exchange": "binance",
            "market": "perpetual_futures",
            "kind": "kline",
            "symbol": "BTCUSDT",
            "interval": "1m",
        }
    ]
    ORDER_TARGETS = []

    def on_market_data(self, data, wallet):
        return None
```

执行：

```bash
.venv/bin/hushine-debug validate strategy.py
```

预期以 `UNSUPPORTED_STRATEGY_DEPENDENCY`/`forbidden_import` 类错误 fail closed，
且不读取数据、不执行用户源码。完成后重新运行 bootstrap 恢复默认 smoke，或恢复
自己的 `strategy.py`；`repair` 不会覆盖用户策略。

## 3. 平台 package v2 回放

1. 登录前端，打开一个 Portfolio 的 `Local Debug`。
2. 激活需要调试的 Strategy。
3. 选择起止时间和一个可路由的 `executor` runtime。
4. 点击 `Generate Debug Package`。

executor 只用于在导出前解析并校验 Strategy 的 `INPUTS` / `ORDER_TARGETS`；下载
后的 import/replay 不再连接该 runtime。页面不能要求用户创建内部 debugger
runtime，也不能让表单覆盖 Strategy 声明的 symbol、interval、market、钱包或余额。

导入前先检查模板，再显式替换工作区策略：

```bash
cd /tmp/hushine-debug-smoke
.venv/bin/hushine-debug import ~/Downloads/debug-package-*.zip
diff -u strategy.py strategy.py.template || true
cp strategy.py.template strategy.py
.venv/bin/hushine-debug replay
```

`diff` 只用于提醒检查；package v2 的精确策略源码写入
`strategy.py.template`，import 不会静默覆盖用户自己的 `strategy.py`。回放前
`INPUTS` 和 `ORDER_TARGETS` 必须与 package 内不可变声明完全一致。

## 4. package v2 验收矩阵

package v2 当前支持 Binance `spot` 与 `perpetual_futures` 的 K-line：

| 场景 | 必须通过的行为 |
|---|---|
| 同币种、不同 interval | 每个 `stream_id` 独立，按事件时间稳定合并 |
| 不同币种 | 所有声明流都被消费，不能只读取第一条 |
| 同一路由、不同 `stream_id` | 两条流不能折叠 |
| Spot + Futures 混合 | 创建各自钱包并按 decision 的 exchange/market/symbol 路由 |
| Spot USDT | 钱包资产使用 `BTC`、`USDT` 等 Binance asset code；订单 symbol 使用 `BTCUSDT` |
| 离线性 | package v2 replay 禁止网络与 downloader fallback |
| 完整性 | manifest、stream Parquet、wallet、Spot metadata/filter facts 任一漂移都在执行前失败 |

仓库级回归：

```bash
cd strategy-debugger-cli
uv run --frozen --extra test pytest \
  tests/test_import_package.py \
  tests/test_spot_package_v2.py \
  tests/test_mixed_route_package_v2.py -q
```

当前边界：仅支持 Binance、K-line、Spot USDT 与 USDT-M Futures；每次
`on_market_data` 回调返回零或一个 `OrderDecision`。不要把这一点写成“一根 bar
可批量返回多条订单”。

## 5. 内部 Bare worker 调试

只有平台内部受控排障才启动连接 RuntimeChannel 的 bare runtime：

```bash
cd strategy-service
make build
DEBUG_WAIT=0 scripts/start-bare-runtime-debugpy.sh \
  --user-id "$USER_ID" --platform-host "$PLATFORM_HOST"
```

Go agent 与 Python worker 通过随机 loopback TCP 通信，不使用 Unix socket，因而
支持 Windows。用户策略断点只阻塞对应 worker/session；agent heartbeat 位于独立
goroutine，不应停止。

## 6. 清理

```bash
rm -rf /tmp/hushine-debug-smoke
```

Windows PowerShell：

```powershell
Remove-Item -Recurse -Force "$HOME\hushine-debug-smoke"
```
