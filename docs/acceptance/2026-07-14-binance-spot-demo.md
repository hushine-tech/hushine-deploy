# Binance Spot Demo 全系统验收交接

状态：等待真实 Demo、真实页面和同页 precise coverage 证据。

最后核验：2026-07-23。本文是可重复执行的 handoff/runbook，不是一次验收结果。
真实 ID、截图、原始 CDP coverage、Runtime coverage 与脱敏交易所证据只写入未跟踪目录：

```text
census-runs/spot-demo-20260714/
```

该目录不得 `git add`，不得包含 API key、secret、签名、Authorization、完整 query
或 credential-derived value。

## 1. 本地前置门禁

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup/hushine-deploy
bash scripts/smoke_hosted_runtime_coverage.test.sh
bash scripts/smoke_spot_demo.test.sh
bash scripts/verify_spot_usdt.test.sh
bash scripts/acceptance/observe_spot_demo.test.sh
./scripts/verify_spot_usdt.sh all-local
```

`all-local` 必须固定包含 `backtest`、`offline`、`ui`、`filters`、`stop`、`futures`，
并且不得偷偷跳过失败项或运行外部 Demo。`release` 是唯一会继续调用真实 Demo 的 scope。

## 2. 构建覆盖率 Runtime 镜像

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup
./strategy-service/scripts/build_strategy_runtime.sh \
  --coverage --no-cache --verify spot-acceptance
docker image inspect \
  hushine/strategy-runtime:executor-coverage-spot-acceptance
```

镜像必须来自当前 strategy-service 与 strategy-library，包含 Go/Python coverage，
通过安装态 dependency/profile/worker smoke；不能依赖 sibling `PYTHONPATH`。

## 3. 真实 Demo observer 与 release scope

本流程使用 Binance Spot Demo Mode：REST 为
`https://demo-api.binance.com`，WebSocket API 为
`wss://demo-ws-api.binance.com/ws-api/v3`。这不是 Spot Testnet；不要把 Demo
credential 发往 `ws-api.testnet.binance.vision`。

Venue 必须先由受信任 provisioning helper 通过 quant-handler 创建并加密保存凭据。
以下流程只接收公开 `VENUE_ID`；credential 只允许存在于继承 FD 中。

```bash
cd /Users/xdy/Workplace/hushine-worktrees/medium-cleanup
coverage_root="$PWD/census-runs/spot-demo-20260714/coverage/runtime-agent"
evidence_file="$coverage_root/exchange-evidence.json"
install -d -m 0700 "$coverage_root"

credential_fd="${BINANCE_SPOT_DEMO_CREDENTIAL_FD:?missing inherited credential FD}"
case "$credential_fd" in (*[!0-9]*|'') exit 1;; esac
test -r "/dev/fd/$credential_fd"

coproc SPOT_OBSERVER {
  python3 hushine-deploy/scripts/acceptance/observe_spot_demo.py \
    --run-id spot-demo-20260714 \
    --user-id "$USER_ID" \
    --portfolio-id "$PORTFOLIO_ID" \
    --venue-id "$VENUE_ID" \
    --coverage-root "$coverage_root" \
    --credential-fd 3 \
    3<&$credential_fd >"$coverage_root/observer.log" 2>&1
}
observer_pid="$SPOT_OBSERVER_PID"
exec {credential_fd}<&-
exec 8>&"${SPOT_OBSERVER[1]}"
observer_pipe_fd="${SPOT_OBSERVER[1]}"
exec {observer_pipe_fd}>&-

cleanup_observer() {
  exec 8>&- 2>/dev/null || true
  kill "$observer_pid" 2>/dev/null || true
  wait "$observer_pid" 2>/dev/null || true
  rm -f "$coverage_root/exchange-evidence.json.tmp"
}
trap cleanup_observer EXIT INT TERM

USER_ID="$USER_ID" \
PORTFOLIO_ID="$PORTFOLIO_ID" \
VENUE_ID="$VENUE_ID" \
SPOT_DEMO_RUN_ID=spot-demo-20260714 \
SPOT_DEMO_EVIDENCE_FILE="$evidence_file" \
SPOT_DEMO_OBSERVER_SESSION_FD=8 \
COVERAGE_IMAGE=hushine/strategy-runtime:executor-coverage-spot-acceptance \
./hushine-deploy/scripts/verify_spot_usdt.sh release \
  "$coverage_root" 8>&8

exec 8>&-
set +e
wait "$observer_pid"
observer_status=$?
set -e
trap - EXIT INT TERM
test "$observer_status" -eq 0
test -f "$evidence_file"
test ! -e "$coverage_root/exchange-evidence.json.tmp"
```

验收必须逐字段比较 exchange order/trade/account、core order/fill、worker wallet 与
reconciliation snapshot。只把 core 投影彼此比较、缺 exchange raw strings、没有
acknowledged `userDataStream.subscribe.signature` 或 reconciliation 未 hard-pass 都失败。

## 4. 浏览器九项检查

在一个新 product tab 中依次完成，所有截图和产品 ID 放在 evidence root：

1. Venue Management 显示 `USDT`、`BTC` 及交易所返回的其他真实 asset；不得显示
   `BTCUSDT` asset。
2. Spot-only 两 symbol/两 interval 策略可启动；Session Chart 分离展示每条 stream
   和自定义 indicator。
3. 同一策略同时使用 Spot/Futures `BTCUSDT` 时，route、wallet、order、stream
   保持隔离。
4. Order History 显示真实 executed quantity、cumulative quote quantity、commission
   amount/asset 和 exchange trade identity。
5. Stop-only 改变 Session 状态但不创建订单。
6. Stop-and-close 显示完整风险提示，只处理 declared targets，且 authoritative close
   response 成功后才进入 `stopped`。
7. 构造 tick/step/notional 非法请求，页面显示 core 返回的精确结构化 filter code。
8. Live Spot 在 UI 禁用；同一身份直接重放 HTTP 仍返回
   `SPOT_LIVE_ROLLOUT_GUARD`。
9. 下载 package v2，关闭 debugger 网络后 import/replay 成功，并覆盖多输入与
   Spot/Futures mixed route。

## 5. 同一 tab 的 precise coverage

Browser owner 必须从开始到结束保持同一个 agent、浏览器 ID、opaque tab ID、
origin、随机 nonce 和 CDP capability：

1. 在应用导航前打开同源 inert coverage page。
2. 在该 tab 上一次性启用 Network 与 Profiler precise coverage。
3. 写入 `O_EXCL` owner-start artifact，之后每份浏览器 envelope 都引用它。
4. 每个用户动作后及时 drain cursor-based network events。
5. 不更换 tab、不复制 tab ID、不启动第二个 CDP owner，完成上面九项流程。
6. 在 `finally` 中由同一 capability 执行 take/stop precise coverage，并关闭
   Network/Profiler。
7. `frontend_coverage` 阶段只归一化 owner 写出的 raw result，不能重新采样。

Profiler 在页面操作后才启动、换 tab、二次 owner 或只保存 DevTools 汇总数字都不
满足验收。

## 6. 数据库与兼容性

- 在四个全新临时数据库分别一次性执行 portfolio/order/control/market bundle。
- 核对 extension、table/view/index/hypertable 与 `schema_migrations` filename。
- 再执行一次相同 bundle，object inventory 和 ledger 必须完全不变。
- 执行 old-reader/new-writer 与 new-reader/legacy-snapshot fixtures。
- 验证已存在 Futures Session 仍可读，Spot/Futures 同 symbol 不互相覆盖。
- 验证关闭任一 Spot capability 只阻止新工作，已有 Session 仍可 close/reconcile drain。

## 7. 发布与回滚 handoff

发布顺序：

1. core-service additive schema/proto/reader-writer
2. control-panel-service authenticated proxy
3. instrumented strategy Runtime image
4. quant-handler
5. quant-frontend

四个 capability 首先全部保持关闭。分别完成 Backtest、Demo、offline 验收后才独立
启用相应开关；`live_spot_usdt` 即使 configured=true 仍必须 effective=false。

回滚按 frontend → handler → Runtime → control-panel → core 的逆序执行，先关闭新
Spot admission。保留 additive protobuf 字段和所有 order/fill/wallet/snapshot/
close-operation/reconciliation 历史，不做 destructive rollback。

## 8. Notion 同步目标

真实证据通过后，只同步以下四个当前页面；历史 B 系列页面只能作为档案，不能作为
当前事实来源：

1. `量化交易系统文档`（当前入口与证据状态）
2. `1 基础运维`（基础设施、schema、启动、coverage、诊断）
3. `2 代码结构和逻辑`（Spot ownership、filters、order/stop/reconciliation）
4. `3 用户手册`（Venue、Strategy、Runtime、Run/Stop、Order History）

每页都必须区分“代码/测试存在”“本地已执行”“真实 Demo 已执行”“真实浏览器已执行”，
并写最后核验日期。不得引用 `B.4 Runtime Management 使用指南` 等历史页证明当前行为。

## 9. 通过条件

只有本地完整回归、真实 Demo 逐字段 reconciliation、九项同页浏览器证据、Runtime
与前端 coverage、fresh bootstrap、Notion 同步和所有仓库远端 push 都完成后，才能
称为“Spot 可用”或“release accepted”。此前只能报告 implementation/local gate 状态。
