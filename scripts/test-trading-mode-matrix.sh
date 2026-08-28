#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORKSPACE="$(dirname -- "${ROOT}")"
REPORT="${TRADING_MATRIX_REPORT:-${ROOT}/docs/test-reports/2026-08-28-trading-mode-matrix.md}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/hushine-trading-matrix.XXXXXX")"
trap 'rm -rf -- "${TMP}"' EXIT

MANIFEST="${TMP}/manifest.tsv"
EVENTS="${TMP}/events.tsv"
: >"${EVENTS}"

cat >"${MANIFEST}" <<'EOF'
SPOT-GTC-FULL	Spot LIMIT GTC, complete liquidity	FILLED; one intent/attempt/order/fill/lifecycle with exact identities	core-order-matrix/spot-GTC-full
SPOT-GTC-PARTIAL	Spot LIMIT GTC, partial liquidity	PARTIALLY_FILLED remains open; exact partial fill persisted once	core-order-matrix/spot-GTC-partial
SPOT-IOC-PARTIAL	Spot LIMIT IOC, partial liquidity	Partial quantity settles and remainder expires	core-order-matrix/spot-IOC-partial
SPOT-FOK-FULL	Spot LIMIT FOK, complete liquidity	FILLED atomically with one exact fill	core-order-matrix/spot-FOK-full
SPOT-FOK-ZERO	Spot LIMIT FOK, insufficient liquidity	EXPIRED with zero persisted fill	core-order-matrix/spot-FOK-zero
FUT-GTC-FULL	Futures LIMIT GTC, complete liquidity	FILLED; lifecycle identities persist exactly	core-order-matrix/futures-GTC-full
FUT-GTC-PARTIAL	Futures LIMIT GTC, partial liquidity	PARTIALLY_FILLED remains open; later fill is recoverable	core-order-matrix/futures-GTC-partial
FUT-IOC-PARTIAL	Futures LIMIT IOC, partial liquidity	Partial quantity settles and remainder expires	core-order-matrix/futures-IOC-partial
FUT-FOK-FULL	Futures LIMIT FOK, complete liquidity	FILLED atomically with one exact fill	core-order-matrix/futures-FOK-full
FUT-FOK-ZERO	Futures LIMIT FOK, insufficient liquidity	EXPIRED with zero persisted fill	core-order-matrix/futures-FOK-zero
FUT-REDUCE-CLOSE	Futures SELL reduce-only close	Intent, attempt, exchange order and fill retain reduce-only close facts	core-order-matrix/futures-reduce-only-close
FUT-REJECT	Futures business rejection	Failed attempt persists; no exchange order, fill or lifecycle event	core-order-matrix/futures-business-rejection
FUT-GTC-DELAYED	Futures GTC REST NEW then delayed websocket fill	Open order transitions to exact final fill without duplicate quantity	core-binance-mock/delayed-GTC-final
FUT-DUPLICATE	Repeated exchange trade report	Canonical trade identity is idempotent at lifecycle storage boundary	core-lifecycle/duplicate-trade
MODE-ONEWAY-CROSS	One-way Cross open, Funding, mark and reduce-only close	BOTH leg initial margin, PnL and wallet/margin/available balances reconcile	strategy-wallet/one-way-cross
MODE-ONEWAY-ISOLATED	One-way Isolated open, Funding, mark and reduce-only close	BOTH leg isolated Funding and all wallet balances reconcile	strategy-wallet/one-way-isolated
MODE-HEDGE-CROSS	Hedge Cross simultaneous LONG/SHORT	Leg quantities, initial margin, realized/unrealized PnL, Funding and balances remain separate	strategy-wallet/hedge-cross
MODE-HEDGE-ISOLATED	Hedge Isolated simultaneous LONG/SHORT	Both isolated legs and all wallet balances reconcile independently	strategy-wallet/hedge-isolated
MODE-INVALID-ONEWAY	One-way order declares LONG or SHORT	Fails before first intent/attempt/order persistence	core-order/invalid-one-way-side
MODE-INVALID-HEDGE	Hedge order declares BOTH	Fails before first intent/attempt/order persistence	core-order/invalid-hedge-side
MULTI-SYMBOL	BTCUSDT, ETHUSDT and ZECUSDT under all four Futures modes	Each symbol and hedge leg projects independently	core-position/BTC-ETH-ZEC-isolation
SPOT-SEMANTICS	Binance Spot order request	No position side, margin mode, leverage or reduceOnly field is sent to Binance Spot	core-binance/spot-request-semantics
SPOT-ASSET-WALLET	Spot fill and duplicate replay	Only base/quote/fee assets change by exact fill delta; no symbol-shaped pseudo asset appears	strategy-wallet/spot-assets-and-idempotency
SPOT-NO-FUNDING	Spot backtest timeline	Contains Klines only and has no Funding coverage/settlement requirement	strategy-backtest/spot-no-funding
SPOT-NO-LEVERAGE	Spot-only strategy declares leverage	Validation fails because Spot has no leverage semantic	strategy-validator/spot-no-leverage
FUNDING-DIRECT	Direct Historical Funding request	Creates the requested Funding stream without a companion	control-marketdata/direct-funding
FUNDING-COMPANION	Historical Futures Kline requested twice	Exactly one Funding companion exists per symbol	control-marketdata/futures-companion-idempotent
FUNDING-SPOT-NONE	Historical Spot Kline	No Funding companion is created	control-marketdata/spot-no-companion
FUNDING-GAP	Open Futures leg with missing/incomplete Funding coverage	Backtest fails closed before strategy callback or settlement	strategy-backtest/funding-gap
FUNDING-RETRY	Missing Funding is supplied and the same backtest is rerun	Retry settles once, advances cursor and then runs strategy callback	strategy-backtest/funding-gap-retry
FUNDING-THREE-DAY	Three days of Funding settlements with page-boundary replay	All three settlements emit/apply exactly once	strategy-backtest/three-day-funding
FUNDING-HEDGE-FORMULA	Hedge LONG and SHORT at same symbol	Each signed quantity is calculated separately as -qty*mark*rate, then summed	core-binance/funding-per-leg
ORDER-CLIENT-IOC	Strategy order client receives IOC partial then expired	Exact fill emits once and terminal remainder does not stay open	strategy-order-client/IOC-partial-expired
SPOT-WALLET-GTC-FULL	Spot GTC full lifecycle applied to wallet	Exact base/quote/fee asset delta; no open order remains	strategy-wallet/spot-GTC-full
SPOT-WALLET-GTC-PARTIAL	Spot GTC partial lifecycle applied to wallet	Exact fill delta plus quote lock for remaining quantity	strategy-wallet/spot-GTC-partial
SPOT-WALLET-IOC-PARTIAL	Spot IOC partial-expired lifecycle applied to wallet	Exact partial fill delta and zero remaining lock	strategy-wallet/spot-IOC-partial
SPOT-WALLET-FOK-FULL	Spot FOK full lifecycle applied to wallet	Exact atomic fill delta; no open order remains	strategy-wallet/spot-FOK-full
SPOT-WALLET-FOK-ZERO	Spot FOK zero-fill expiry applied to wallet	No asset mutation and no open order	strategy-wallet/spot-FOK-zero
FUT-WALLET-GTC-FULL	Futures GTC full lifecycle applied to wallet	Exact fee/wallet and position delta; no open order remains	strategy-wallet/futures-GTC-full
FUT-WALLET-GTC-PARTIAL	Futures GTC partial lifecycle applied to wallet	Exact partial position/fee delta and remaining open order	strategy-wallet/futures-GTC-partial
FUT-WALLET-IOC-PARTIAL	Futures IOC partial-expired lifecycle applied to wallet	Exact partial position/fee delta and no open order	strategy-wallet/futures-IOC-partial
FUT-WALLET-FOK-FULL	Futures FOK full lifecycle applied to wallet	Exact atomic position/fee delta; no open order remains	strategy-wallet/futures-FOK-full
FUT-WALLET-FOK-ZERO	Futures FOK zero-fill expiry applied to wallet	No wallet or position mutation and no open order	strategy-wallet/futures-FOK-zero
EOF

record_cells() {
  local status="$1" actual="$2" evidence="$3" ids="$4" id
  for id in ${ids}; do
    printf '%s\t%s\t%s\t%s\n' "${id}" "${status}" "${actual}" "${evidence}" >>"${EVENTS}"
  done
}

failed=0
run_group() {
  local label="$1" repo="$2" command="$3" evidence="$4" ids="$5"
  local log="${TMP}/${label}.log"
  echo "[trading-matrix] ${label}"
  if (cd -- "${repo}" && bash -lc "${command}") >"${log}" 2>&1; then
    record_cells PASS "focused hermetic test passed" "${evidence}" "${ids}"
  else
    failed=1
    record_cells FAIL "focused hermetic test failed; see ${label}.log" "${evidence}" "${ids}"
    sed -n '1,200p' "${log}" >&2
  fi
}

if [[ -n "${TRADING_MATRIX_EVENTS_FILE:-}" ]]; then
  cp -- "${TRADING_MATRIX_EVENTS_FILE}" "${EVENTS}"
else
  run_group core-order-lifecycle "${WORKSPACE}/core-service" \
    "go test ./internal/order/service -run '^TestTradingModeMatrixPersistsEveryBinanceOrderOutcome$' -count=1" \
    core-order-matrix \
    "SPOT-GTC-FULL SPOT-GTC-PARTIAL SPOT-IOC-PARTIAL SPOT-FOK-FULL SPOT-FOK-ZERO FUT-GTC-FULL FUT-GTC-PARTIAL FUT-IOC-PARTIAL FUT-FOK-FULL FUT-FOK-ZERO FUT-REDUCE-CLOSE FUT-REJECT"
  run_group core-delayed-gtc "${WORKSPACE}/core-service" \
    "go test ./internal/exchange/binance ./internal/exchange/binance/mockserver -run 'TestBinanceFactoryPlacesOrderAndReceivesMockWSPartialFill|TestMockServerFuturesOrderPartialThenTradesComplete|TestMockServerScene3EmitsDelayedWebsocketFinalFill' -count=1" \
    core-binance-mock/delayed-GTC-final "FUT-GTC-DELAYED"
  run_group core-duplicate-fill "${WORKSPACE}/core-service" \
    "go test ./internal/order/lifecycle -run '^TestIngestorPassesDuplicateTradeToStore$' -count=1" \
    core-lifecycle/duplicate-trade "FUT-DUPLICATE"
  run_group core-invalid-modes "${WORKSPACE}/core-service" \
    "go test ./internal/order/service -run '^TestPlaceOrderPositionModeRejectsAmbiguousPositionSideBeforePersistence$' -count=1" \
    core-order/invalid-position-side "MODE-INVALID-ONEWAY MODE-INVALID-HEDGE"
  run_group core-position-matrix "${WORKSPACE}/core-service" \
    "go test ./internal/income -run '^TestPositionProjectionTradingModeMatrixKeepsBTCETHAndZECIndependent$' -count=1" \
    core-position/BTC-ETH-ZEC-isolation "MULTI-SYMBOL"
  run_group core-spot-fields "${WORKSPACE}/core-service" \
    "go test ./internal/exchange/binance -run '^TestBinanceFactoryMockCapturesOrderConditionCombinations$' -count=1" \
    core-binance/spot-request-semantics "SPOT-SEMANTICS"
  run_group core-funding-formula "${WORKSPACE}/core-service" \
    "go test ./internal/exchange/binance -run '^TestFundingSettlementCalculatorHedgeCalculatesEachSignedLeg$' -count=1" \
    core-binance/funding-per-leg "FUNDING-HEDGE-FORMULA"
  run_group control-historical-funding "${WORKSPACE}/control-panel-service" \
    "go test ./internal/marketdata -run 'TestCreateMarketDataRequest_HistoricalFuturesEnsuresFundingCompanionIdempotently|TestCreateMarketDataRequest_HistoricalFundingIsDirectAndDoesNotCreateCompanion|TestCreateMarketDataRequest_HistoricalCompanionsRemainPerSymbolAndSpotHasNone' -count=1" \
    control-marketdata/historical-funding \
    "FUNDING-DIRECT FUNDING-COMPANION FUNDING-SPOT-NONE"
  run_group strategy-wallet-modes "${WORKSPACE}/strategy-service" \
    "PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest -q tests/test_backtest_funding_wallet.py -k 'test_futures_position_margin_wallet_matrix_tracks_each_leg_and_balance'" \
    strategy-wallet/four-modes \
    "MODE-ONEWAY-CROSS MODE-ONEWAY-ISOLATED MODE-HEDGE-CROSS MODE-HEDGE-ISOLATED"
  run_group strategy-spot-semantics "${WORKSPACE}/strategy-service" \
    "PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest -q tests/test_spot_end_to_end.py::test_spot_buy_applies_actual_fill_and_bnb_commission_once_across_replays tests/test_spot_end_to_end.py::test_spot_wallet_uses_asset_codes_and_market_data_never_creates_symbol_asset tests/test_backtest_pages.py::test_spot_timeline_contains_only_klines_and_no_funding_coverage_requirement tests/test_strategy_validator.py::test_validator_rejects_strategy_leverage_for_spot_only_targets_at_assignment" \
    strategy-spot/asset-wallet-funding-leverage \
    "SPOT-ASSET-WALLET SPOT-NO-FUNDING SPOT-NO-LEVERAGE"
  run_group strategy-funding-gap "${WORKSPACE}/strategy-service" \
    "PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest -q tests/test_grpc_server.py -k 'test_backtest_incomplete_funding_coverage_is_typed_only_with_open_futures_leg or test_backtest_funding_gap_can_be_filled_and_same_run_retried'" \
    strategy-backtest/funding-gap-and-retry "FUNDING-GAP FUNDING-RETRY"
  run_group strategy-three-day "${WORKSPACE}/strategy-service" \
    "PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest -q tests/test_backtest_pages.py::test_three_day_funding_timeline_emits_every_settlement_once_across_pages tests/test_backtest_funding_wallet.py::test_three_day_funding_entries_apply_once_without_netting_hedge_details" \
    strategy-backtest/three-day-funding "FUNDING-THREE-DAY"
  run_group strategy-ioc "${WORKSPACE}/strategy-service" \
    "PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest -q tests/test_order_client.py::test_place_order_ioc_partial_expired_emits_terminal_fill_event" \
    strategy-order-client/IOC-partial-expired "ORDER-CLIENT-IOC"
  run_group strategy-tif-wallets "${WORKSPACE}/strategy-service" \
    "PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest -q tests/test_trading_mode_wallet_matrix.py" \
    strategy-wallet/TIF-deltas \
    "SPOT-WALLET-GTC-FULL SPOT-WALLET-GTC-PARTIAL SPOT-WALLET-IOC-PARTIAL SPOT-WALLET-FOK-FULL SPOT-WALLET-FOK-ZERO FUT-WALLET-GTC-FULL FUT-WALLET-GTC-PARTIAL FUT-WALLET-IOC-PARTIAL FUT-WALLET-FOK-FULL FUT-WALLET-FOK-ZERO"
fi

mkdir -p -- "$(dirname -- "${REPORT}")"
python3 - "${MANIFEST}" "${EVENTS}" "${REPORT}" <<'PY'
from __future__ import annotations

import pathlib
import sys

manifest_path, events_path, report_path = map(pathlib.Path, sys.argv[1:])

def rows(path: pathlib.Path, columns: int):
    result = []
    for line_number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not raw:
            continue
        fields = raw.split("\t")
        if len(fields) != columns or any(not field.strip() for field in fields):
            raise SystemExit(f"invalid matrix row {path}:{line_number}")
        result.append(tuple(field.strip() for field in fields))
    return result

manifest_rows = rows(manifest_path, 4)
event_rows = rows(events_path, 4)
manifest = {row[0]: row for row in manifest_rows}
if len(manifest) != len(manifest_rows):
    raise SystemExit("duplicate cell in trading matrix manifest")

events = {}
errors = []
for cell_id, status, actual, evidence in event_rows:
    if cell_id not in manifest:
        errors.append(f"unknown cell {cell_id}")
        continue
    if cell_id in events:
        errors.append(f"duplicate result for {cell_id}")
        continue
    if status not in {"PASS", "FAIL"}:
        errors.append(f"invalid status for {cell_id}: {status}")
    events[cell_id] = (status, actual, evidence)

for cell_id in manifest:
    if cell_id not in events:
        errors.append(f"missing result for {cell_id}")
    elif events[cell_id][0] != "PASS":
        errors.append(f"non-PASS result for {cell_id}")

def esc(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ")

lines = [
    "# Trading Mode Matrix — 2026-08-28",
    "",
    "Hermetic Binance mock and local service tests only; no real Binance API was called.",
    "",
    "| Cell | Input | Expected | Actual | Evidence ID | Error / 误差 | Status |",
    "| --- | --- | --- | --- | --- | --- | --- |",
]
for cell_id, input_value, expected, default_evidence in manifest_rows:
    event = events.get(cell_id)
    if event is None:
        status, actual, evidence = "NOT RUN", "No executed evidence was recorded", default_evidence
    else:
        status, actual, evidence = event
    error = "0" if status == "PASS" else actual
    lines.append(
        f"| {esc(cell_id)} | {esc(input_value)} | {esc(expected)} | "
        f"{esc(actual)} | {esc(evidence)} | {esc(error)} | {esc(status)} |"
    )
lines.extend(["", f"Overall: **{'FAIL' if errors else 'PASS'}**.", ""])
if errors:
    lines.extend(["Validation errors:", ""] + [f"- {error}" for error in errors] + [""])
report_path.write_text("\n".join(lines), encoding="utf-8")
if errors:
    raise SystemExit("; ".join(errors))
PY
validator_status=$?

if [[ ${failed} -ne 0 || ${validator_status} -ne 0 ]]; then
  echo "trading mode matrix: FAIL (report: ${REPORT})" >&2
  exit 1
fi
echo "trading mode matrix: PASS (report: ${REPORT})"
