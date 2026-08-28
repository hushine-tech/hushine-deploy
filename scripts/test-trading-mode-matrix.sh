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
SPOT-GTC-FULL	Spot LIMIT GTC, complete liquidity	FILLED; one intent/attempt/order/fill/lifecycle with exact identities	go:TestTradingModeMatrixPersistsEveryBinanceOrderOutcome/spot_GTC_full
SPOT-GTC-PARTIAL	Spot LIMIT GTC, partial liquidity	PARTIALLY_FILLED remains open; exact partial fill persisted once	go:TestTradingModeMatrixPersistsEveryBinanceOrderOutcome/spot_GTC_partial_remains_open
SPOT-IOC-PARTIAL	Spot LIMIT IOC, partial liquidity	Partial quantity settles and remainder expires	go:TestTradingModeMatrixPersistsEveryBinanceOrderOutcome/spot_IOC_partial_expires_remainder
SPOT-FOK-FULL	Spot LIMIT FOK, complete liquidity	FILLED atomically with one exact fill	go:TestTradingModeMatrixPersistsEveryBinanceOrderOutcome/spot_FOK_full
SPOT-FOK-ZERO	Spot LIMIT FOK, insufficient liquidity	EXPIRED with zero persisted fill	go:TestTradingModeMatrixPersistsEveryBinanceOrderOutcome/spot_FOK_zero_fill
FUT-GTC-FULL	Futures LIMIT GTC, complete liquidity	FILLED; lifecycle identities persist exactly	go:TestTradingModeMatrixPersistsEveryBinanceOrderOutcome/futures_GTC_full
FUT-GTC-PARTIAL	Futures LIMIT GTC, partial liquidity	PARTIALLY_FILLED remains open; later fill is recoverable	go:TestTradingModeMatrixPersistsEveryBinanceOrderOutcome/futures_GTC_partial_remains_open
FUT-IOC-PARTIAL	Futures LIMIT IOC, partial liquidity	Partial quantity settles and remainder expires	go:TestTradingModeMatrixPersistsEveryBinanceOrderOutcome/futures_IOC_partial_expires_remainder
FUT-FOK-FULL	Futures LIMIT FOK, complete liquidity	FILLED atomically with one exact fill	go:TestTradingModeMatrixPersistsEveryBinanceOrderOutcome/futures_FOK_full
FUT-FOK-ZERO	Futures LIMIT FOK, insufficient liquidity	EXPIRED with zero persisted fill	go:TestTradingModeMatrixPersistsEveryBinanceOrderOutcome/futures_FOK_zero_fill
FUT-REDUCE-CLOSE	Futures SELL reduce-only close	Intent, attempt, exchange order and fill retain reduce-only close facts	go:TestTradingModeMatrixPersistsEveryBinanceOrderOutcome/futures_reduce-only_close
FUT-REJECT	Futures business rejection	Failed attempt persists; no exchange order, fill or lifecycle event	go:TestTradingModeMatrixPersistsEveryBinanceOrderOutcome/futures_business_rejection
FUT-GTC-DELAYED	Futures GTC REST NEW, websocket partial fill, ingestor, then REST recovery	Open order transitions through exact 0.2 partial to exact 0.5 final fill without duplicate quantity	go:TestBinanceFactoryPlacesOrderAndReceivesMockWSPartialFill;go:TestUserDataIngestorWritesPartialFillEvent;go:TestScannerRestRecoveryCompletesPartialOrderWithMockBinance
FUT-DUPLICATE	Repeated exchange trade report	Canonical trade identity is idempotent at lifecycle storage boundary	go:TestSaveLifecycleEventDeduplicatesExchangeTrade
MODE-ONEWAY-CROSS	One-way Cross open, Funding, mark and reduce-only close	BOTH leg initial margin, PnL and wallet/margin/available balances reconcile	pytest:tests/test_backtest_funding_wallet.py::test_futures_position_margin_wallet_matrix_tracks_each_leg_and_balance[one-way-cross]
MODE-ONEWAY-ISOLATED	One-way Isolated open, Funding, mark and reduce-only close	BOTH leg isolated Funding and all wallet balances reconcile	pytest:tests/test_backtest_funding_wallet.py::test_futures_position_margin_wallet_matrix_tracks_each_leg_and_balance[one-way-isolated]
MODE-HEDGE-CROSS	Hedge Cross simultaneous LONG/SHORT	Leg quantities, initial margin, realized/unrealized PnL, Funding and balances remain separate	pytest:tests/test_backtest_funding_wallet.py::test_futures_position_margin_wallet_matrix_tracks_each_leg_and_balance[hedge-cross]
MODE-HEDGE-ISOLATED	Hedge Isolated simultaneous LONG/SHORT	Both isolated legs and all wallet balances reconcile independently	pytest:tests/test_backtest_funding_wallet.py::test_futures_position_margin_wallet_matrix_tracks_each_leg_and_balance[hedge-isolated]
MODE-INVALID-ONEWAY	One-way order declares LONG or SHORT	Fails before first intent/attempt/order persistence	go:TestPlaceOrderPositionModeRejectsAmbiguousPositionSideBeforePersistence/ONE_WAY_LONG;go:TestPlaceOrderPositionModeRejectsAmbiguousPositionSideBeforePersistence/ONE_WAY_SHORT
MODE-INVALID-HEDGE	Hedge order declares BOTH	Fails before first intent/attempt/order persistence	go:TestPlaceOrderPositionModeRejectsAmbiguousPositionSideBeforePersistence/HEDGE_missing_or_BOTH
MULTI-SYMBOL	BTCUSDT, ETHUSDT and ZECUSDT under all four Futures modes	Each symbol and hedge leg projects independently	go:TestPositionProjectionTradingModeMatrixKeepsBTCETHAndZECIndependent
SPOT-SEMANTICS	Binance Spot order request	No position side, margin mode, leverage or reduceOnly field is sent to Binance Spot	go:TestBinanceFactoryMockCapturesOrderConditionCombinations
SPOT-ASSET-WALLET	Spot fill and duplicate replay	Only base/quote/fee assets change by exact fill delta; no symbol-shaped pseudo asset appears	pytest:tests/test_spot_end_to_end.py::test_spot_buy_applies_actual_fill_and_bnb_commission_once_across_replays;pytest:tests/test_spot_end_to_end.py::test_spot_wallet_uses_asset_codes_and_market_data_never_creates_symbol_asset
SPOT-NO-FUNDING	Spot backtest timeline	Contains Klines only and has no Funding coverage/settlement requirement	pytest:tests/test_backtest_pages.py::test_spot_timeline_contains_only_klines_and_no_funding_coverage_requirement
SPOT-NO-LEVERAGE	Spot-only strategy declares leverage	Validation fails because Spot has no leverage semantic	pytest:tests/test_strategy_validator.py::test_validator_rejects_strategy_leverage_for_spot_only_targets_at_assignment
FUNDING-DIRECT	Direct Historical Funding request	Creates the requested Funding stream without a companion	go:TestCreateMarketDataRequest_HistoricalFundingIsDirectAndDoesNotCreateCompanion
FUNDING-COMPANION	Historical Futures Kline requested twice	Exactly one Funding companion exists per symbol	go:TestCreateMarketDataRequest_HistoricalFuturesEnsuresFundingCompanionIdempotently
FUNDING-SPOT-NONE	Historical Spot Kline	No Funding companion is created	go:TestCreateMarketDataRequest_HistoricalCompanionsRemainPerSymbolAndSpotHasNone
FUNDING-GAP	Open Futures leg with missing/incomplete Funding coverage	Backtest fails closed before strategy callback or settlement	pytest:tests/test_grpc_server.py::test_backtest_incomplete_funding_coverage_is_typed_only_with_open_futures_leg[True-False];pytest:tests/test_grpc_server.py::test_backtest_incomplete_funding_coverage_is_typed_only_with_open_futures_leg[True-None];pytest:tests/test_grpc_server.py::test_backtest_incomplete_funding_coverage_is_typed_only_with_open_futures_leg[False-False]
FUNDING-RETRY	Missing Funding is supplied and the same backtest is rerun	Retry settles once, advances cursor and then runs strategy callback	pytest:tests/test_grpc_server.py::test_backtest_funding_gap_can_be_filled_and_same_run_retried
FUNDING-THREE-DAY	Three days of Funding settlements with page-boundary replay	All three settlements emit/apply exactly once	pytest:tests/test_backtest_pages.py::test_three_day_funding_timeline_emits_every_settlement_once_across_pages;pytest:tests/test_backtest_funding_wallet.py::test_three_day_funding_entries_apply_once_without_netting_hedge_details
FUNDING-HEDGE-FORMULA	Hedge LONG and SHORT at same symbol	Each signed quantity is calculated separately as -qty*mark*rate, then summed	go:TestFundingSettlementCalculatorHedgeCalculatesEachSignedLeg
ORDER-CLIENT-IOC	Strategy order client receives IOC partial then expired	Exact fill emits once and terminal remainder does not stay open	pytest:tests/test_order_client.py::test_place_order_ioc_partial_expired_emits_terminal_fill_event
SPOT-WALLET-FULL	Spot full lifecycle and duplicate terminal replay applied to wallet	Exact base/quote/fee asset delta once; no open order remains	pytest:tests/test_trading_mode_wallet_matrix.py::test_spot_canonical_order_outcome_wallet_delta_matrix[full]
SPOT-WALLET-GTC-PARTIAL	Spot GTC partial lifecycle applied to wallet	Exact fill delta plus quote lock for remaining quantity	pytest:tests/test_trading_mode_wallet_matrix.py::test_spot_canonical_order_outcome_wallet_delta_matrix[gtc-partial]
SPOT-WALLET-IOC-PARTIAL	Spot IOC partial then expired replay applied to wallet	Exact partial fill delta once and zero remaining lock	pytest:tests/test_trading_mode_wallet_matrix.py::test_spot_canonical_order_outcome_wallet_delta_matrix[ioc-partial-expired]
SPOT-WALLET-FOK-ZERO	Spot FOK zero-fill expiry applied to wallet	No asset mutation and no open order	pytest:tests/test_trading_mode_wallet_matrix.py::test_spot_canonical_order_outcome_wallet_delta_matrix[fok-zero]
FUT-WALLET-FULL	Futures full lifecycle and duplicate terminal replay applied to wallet	Exact fee/wallet and position delta once; no open order remains	pytest:tests/test_trading_mode_wallet_matrix.py::test_futures_canonical_order_outcome_wallet_delta_matrix[full]
FUT-WALLET-GTC-PARTIAL	Futures GTC partial lifecycle applied to wallet	Exact partial position/fee delta and remaining open order	pytest:tests/test_trading_mode_wallet_matrix.py::test_futures_canonical_order_outcome_wallet_delta_matrix[gtc-partial]
FUT-WALLET-IOC-PARTIAL	Futures IOC partial then expired replay applied to wallet	Exact partial position/fee delta once and no open order	pytest:tests/test_trading_mode_wallet_matrix.py::test_futures_canonical_order_outcome_wallet_delta_matrix[ioc-partial-expired]
FUT-WALLET-FOK-ZERO	Futures FOK zero-fill expiry applied to wallet	No wallet or position mutation and no open order	pytest:tests/test_trading_mode_wallet_matrix.py::test_futures_canonical_order_outcome_wallet_delta_matrix[fok-zero]
EOF

manifest_evidence() {
  awk -F '\t' -v id="$1" '$1 == id { print $4; exit }' "${MANIFEST}"
}

actual_for_cell() {
  case "$1" in
    SPOT-GTC-FULL|SPOT-FOK-FULL|FUT-GTC-FULL|FUT-FOK-FULL)
      echo "status=FILLED; executed=1; intents=1 attempts=1 orders=1 fills=1 lifecycle=1" ;;
    SPOT-GTC-PARTIAL|FUT-GTC-PARTIAL)
      echo "status=PARTIALLY_FILLED; executed=0.2; orders=1 fills=1 lifecycle=1; remains open" ;;
    SPOT-IOC-PARTIAL|FUT-IOC-PARTIAL)
      echo "status=EXPIRED; executed=0.2; orders=1 fills=1 lifecycle=1; remainder=0" ;;
    SPOT-FOK-ZERO|FUT-FOK-ZERO)
      echo "status=EXPIRED; executed=0; orders=1 fills=0 lifecycle=0" ;;
    FUT-REDUCE-CLOSE)
      echo "status=FILLED; side=SELL; reduce_only=true on intent attempt and exchange order" ;;
    FUT-REJECT)
      echo "status=FAILED; intents=1 attempts=1 orders=0 fills=0 lifecycle=0" ;;
    FUT-GTC-DELAYED)
      echo "REST status=NEW; websocket partial=0.2 persisted by ingestor; REST recovery adds 0.2+0.3 and terminal executed=0.5" ;;
    FUT-DUPLICATE)
      echo "first_event_id=second_event_id; persisted rows=1; original payload unchanged" ;;
    MODE-ONEWAY-CROSS)
      echo "BOTH margin=220; UPNL=20; Funding=-0.022; WB/MB/AB=998.978/1018.978/798.978; close realized=5" ;;
    MODE-ONEWAY-ISOLATED)
      echo "BOTH margin=220; UPNL=20; Funding=-0.022 isolated; WB/MB/AB=999/1019/799; close realized=5" ;;
    MODE-HEDGE-CROSS)
      echo "LONG/SHORT margin=220/110; UPNL=20/10; Funding=-0.022/+0.011; WB/MB/AB=998.489/1028.489/698.489" ;;
    MODE-HEDGE-ISOLATED)
      echo "LONG/SHORT margin=220/110; UPNL=20/10; Funding=-0.022/+0.011 isolated; WB/MB/AB=998.5/1028.5/698.5" ;;
    MODE-INVALID-ONEWAY|MODE-INVALID-HEDGE)
      echo "executor calls=0; intents=0 attempts=0 orders=0 fills=0" ;;
    MULTI-SYMBOL)
      echo "one-way BTC/ETH/ZEC=1.25/2.5/3.75; hedge SHORT=-0.75/-1.5/-2.25; cross and isolated independent" ;;
    SPOT-SEMANTICS)
      echo "GTC/IOC/FOK preserved; positionSide marginMode leverage absent; reduceOnly not sent" ;;
    SPOT-ASSET-WALLET)
      echo "BTC=0.01; USDT=1000; BNB=0.999; duplicate applied once; BTCUSDT asset absent" ;;
    SPOT-NO-FUNDING)
      echo "timeline event kinds={kline}; funding coverage absent; settlement count=0" ;;
    SPOT-NO-LEVERAGE)
      echo "validation rejects Spot STRATEGY_LEVERAGE before execution" ;;
    FUNDING-DIRECT)
      echo "one requested Historical Funding stream; companion count=0" ;;
    FUNDING-COMPANION)
      echo "two identical Futures Kline requests produce exactly one Funding companion" ;;
    FUNDING-SPOT-NONE)
      echo "Spot Kline request produces zero Funding companions" ;;
    FUNDING-GAP)
      echo "strategy callbacks=0; funding settlements=0; typed incomplete-coverage failure" ;;
    FUNDING-RETRY)
      echo "after coverage fill: funding query=1 callback=1 settlement=1 wallet=99.99 cursor=81" ;;
    FUNDING-THREE-DAY)
      echo "settlement timestamps=3; each emitted/applied once; wallet=99.985 cursor=203" ;;
    FUNDING-HEDGE-FORMULA)
      echo "LONG=-0.020; SHORT=+0.015; sum=-0.005, each computed before summing" ;;
    ORDER-CLIENT-IOC)
      echo "status=EXPIRED; fill=0.004; remaining=0.016; emitted fill count=1" ;;
    SPOT-WALLET-FULL)
      echo "BTC=0.01; USDT free/locked=500/0; BNB=0.999; open=0; terminal replay delta=0" ;;
    SPOT-WALLET-GTC-PARTIAL)
      echo "BTC=0.004; USDT free/locked=500/300; BNB=0.999; open=1" ;;
    SPOT-WALLET-IOC-PARTIAL)
      echo "BTC=0.004; USDT free/locked=800/0; BNB=0.999; open=0; expiry replay delta=0" ;;
    SPOT-WALLET-FOK-ZERO)
      echo "BTC asset absent; USDT=1000; BNB=1; open=0" ;;
    FUT-WALLET-FULL)
      echo "wallet=999.96; position qty=1; open=0; terminal replay delta=0" ;;
    FUT-WALLET-GTC-PARTIAL)
      echo "wallet=999.992; position qty=0.2; open=1" ;;
    FUT-WALLET-IOC-PARTIAL)
      echo "wallet=999.992; position qty=0.2; open=0; expiry replay delta=0" ;;
    FUT-WALLET-FOK-ZERO)
      echo "wallet=1000; position absent; open=0" ;;
    *)
      echo "unmapped matrix cell" ; return 1 ;;
  esac
}

record_cells() {
  local status="$1" failure="$2" ids="$3" id actual evidence
  for id in ${ids}; do
    evidence="$(manifest_evidence "${id}")"
    if [[ "${status}" == "PASS" ]]; then
      actual="$(actual_for_cell "${id}")" || {
        status=FAIL
        actual="no exact assertion summary is defined"
      }
    else
      actual="${failure}"
    fi
    printf '%s\t%s\t%s\t%s\n' "${id}" "${status}" "${actual}" "${evidence}" >>"${EVENTS}"
  done
}

failed=0
run_group() {
  local label="$1" repo="$2" command="$3" _group_evidence="$4" ids="$5" markers="${6:-}"
  local log="${TMP}/${label}.log" marker marker_missing=0
  echo "[trading-matrix] ${label}"
  if (cd -- "${repo}" && bash -c "${command}") >"${log}" 2>&1; then
    if [[ -n "${markers}" ]]; then
      while IFS= read -r marker; do
        [[ -z "${marker}" ]] && continue
        if ! grep -Fq -- "${marker}" "${log}"; then
          echo "missing executed-test marker: ${marker}" >&2
          marker_missing=1
        fi
      done <<<"${markers}"
    fi
    if [[ ${marker_missing} -eq 0 ]]; then
      record_cells PASS "" "${ids}"
    else
      failed=1
      record_cells FAIL "test command passed but required matrix case did not execute" "${ids}"
    fi
  else
    failed=1
    record_cells FAIL "focused hermetic test failed; see ${label}.log" "${ids}"
    sed -n '1,200p' "${log}" >&2
  fi
}

if [[ -n "${TRADING_MATRIX_EVENTS_FILE:-}" ]]; then
  if [[ "${TRADING_MATRIX_CONTRACT_TEST_ONLY:-}" != "1" ]] || ! python3 - "${TMPDIR:-/tmp}" "${REPORT}" "${TRADING_MATRIX_EVENTS_FILE}" <<'PY'
from pathlib import Path
import sys

tmp_root = Path(sys.argv[1]).resolve()
report = Path(sys.argv[2]).resolve()
events = Path(sys.argv[3]).resolve()
private_dir = report.parent
valid = (
    private_dir.parent == tmp_root
    and private_dir.name.startswith("hushine-trading-matrix-contract.")
    and events.parent == private_dir
)
raise SystemExit(0 if valid else 1)
PY
  then
    echo "synthetic matrix evidence is restricted to the contract test directory" >&2
    exit 2
  fi
  cp -- "${TRADING_MATRIX_EVENTS_FILE}" "${EVENTS}"
else
  run_group core-order-lifecycle "${WORKSPACE}/core-service" \
    "go test -v ./internal/order/service -run '^TestTradingModeMatrixPersistsEveryBinanceOrderOutcome$' -count=1" \
    core-order-matrix \
    "SPOT-GTC-FULL SPOT-GTC-PARTIAL SPOT-IOC-PARTIAL SPOT-FOK-FULL SPOT-FOK-ZERO FUT-GTC-FULL FUT-GTC-PARTIAL FUT-IOC-PARTIAL FUT-FOK-FULL FUT-FOK-ZERO FUT-REDUCE-CLOSE FUT-REJECT" \
    $'--- PASS: TestTradingModeMatrixPersistsEveryBinanceOrderOutcome/spot_GTC_full\n--- PASS: TestTradingModeMatrixPersistsEveryBinanceOrderOutcome/spot_GTC_partial_remains_open\n--- PASS: TestTradingModeMatrixPersistsEveryBinanceOrderOutcome/spot_IOC_partial_expires_remainder\n--- PASS: TestTradingModeMatrixPersistsEveryBinanceOrderOutcome/spot_FOK_full\n--- PASS: TestTradingModeMatrixPersistsEveryBinanceOrderOutcome/spot_FOK_zero_fill\n--- PASS: TestTradingModeMatrixPersistsEveryBinanceOrderOutcome/futures_GTC_full\n--- PASS: TestTradingModeMatrixPersistsEveryBinanceOrderOutcome/futures_GTC_partial_remains_open\n--- PASS: TestTradingModeMatrixPersistsEveryBinanceOrderOutcome/futures_IOC_partial_expires_remainder\n--- PASS: TestTradingModeMatrixPersistsEveryBinanceOrderOutcome/futures_FOK_full\n--- PASS: TestTradingModeMatrixPersistsEveryBinanceOrderOutcome/futures_FOK_zero_fill\n--- PASS: TestTradingModeMatrixPersistsEveryBinanceOrderOutcome/futures_reduce-only_close\n--- PASS: TestTradingModeMatrixPersistsEveryBinanceOrderOutcome/futures_business_rejection'
  run_group core-delayed-gtc "${WORKSPACE}/core-service" \
    "go test -v ./internal/exchange/binance ./internal/order/lifecycle -run '^(TestBinanceFactoryPlacesOrderAndReceivesMockWSPartialFill|TestUserDataIngestorWritesPartialFillEvent|TestScannerRestRecoveryCompletesPartialOrderWithMockBinance)$' -count=1" \
    core-binance-mock/delayed-GTC-final "FUT-GTC-DELAYED" \
    $'--- PASS: TestBinanceFactoryPlacesOrderAndReceivesMockWSPartialFill\n--- PASS: TestUserDataIngestorWritesPartialFillEvent\n--- PASS: TestScannerRestRecoveryCompletesPartialOrderWithMockBinance'
  run_group core-duplicate-fill "${WORKSPACE}/core-service" \
    "env ORDER_DATABASE_HOST=127.0.0.1 ORDER_DATABASE_PORT=5432 ORDER_DATABASE_USER=postgres ORDER_DATABASE_PASSWORD=postgres ORDER_DATABASE_DBNAME=order ORDER_DATABASE_SSLMODE=disable go test -v ./internal/order/repository -run '^TestSaveLifecycleEventDeduplicatesExchangeTrade$' -count=1" \
    core-lifecycle/duplicate-trade "FUT-DUPLICATE" \
    '--- PASS: TestSaveLifecycleEventDeduplicatesExchangeTrade'
  run_group core-invalid-modes "${WORKSPACE}/core-service" \
    "go test -v ./internal/order/service -run '^TestPlaceOrderPositionModeRejectsAmbiguousPositionSideBeforePersistence$' -count=1" \
    core-order/invalid-position-side "MODE-INVALID-ONEWAY MODE-INVALID-HEDGE" \
    $'--- PASS: TestPlaceOrderPositionModeRejectsAmbiguousPositionSideBeforePersistence/HEDGE_missing_or_BOTH\n--- PASS: TestPlaceOrderPositionModeRejectsAmbiguousPositionSideBeforePersistence/HEDGE_invalid\n--- PASS: TestPlaceOrderPositionModeRejectsAmbiguousPositionSideBeforePersistence/ONE_WAY_LONG\n--- PASS: TestPlaceOrderPositionModeRejectsAmbiguousPositionSideBeforePersistence/ONE_WAY_SHORT'
  run_group core-position-matrix "${WORKSPACE}/core-service" \
    "go test -v ./internal/income -run '^TestPositionProjectionTradingModeMatrixKeepsBTCETHAndZECIndependent$' -count=1" \
    core-position/BTC-ETH-ZEC-isolation "MULTI-SYMBOL" \
    $'--- PASS: TestPositionProjectionTradingModeMatrixKeepsBTCETHAndZECIndependent/one-way-cross\n--- PASS: TestPositionProjectionTradingModeMatrixKeepsBTCETHAndZECIndependent/one-way-isolated\n--- PASS: TestPositionProjectionTradingModeMatrixKeepsBTCETHAndZECIndependent/hedge-cross\n--- PASS: TestPositionProjectionTradingModeMatrixKeepsBTCETHAndZECIndependent/hedge-isolated'
  run_group core-spot-fields "${WORKSPACE}/core-service" \
    "go test -v ./internal/exchange/binance -run '^TestBinanceFactoryMockCapturesOrderConditionCombinations$' -count=1" \
    core-binance/spot-request-semantics "SPOT-SEMANTICS" \
    $'--- PASS: TestBinanceFactoryMockCapturesOrderConditionCombinations/spot_GTC_passes_GTC\n--- PASS: TestBinanceFactoryMockCapturesOrderConditionCombinations/spot_IOC_passes_IOC\n--- PASS: TestBinanceFactoryMockCapturesOrderConditionCombinations/spot_FOK_passes_FOK\n--- PASS: TestBinanceFactoryMockCapturesOrderConditionCombinations/spot_reduce-only_sell_is_platform-only'
  run_group core-funding-formula "${WORKSPACE}/core-service" \
    "go test -v ./internal/exchange/binance -run '^TestFundingSettlementCalculatorHedgeCalculatesEachSignedLeg$' -count=1" \
    core-binance/funding-per-leg "FUNDING-HEDGE-FORMULA" \
    '--- PASS: TestFundingSettlementCalculatorHedgeCalculatesEachSignedLeg'
  run_group control-historical-funding "${WORKSPACE}/control-panel-service" \
    "go test -v ./internal/marketdata -run 'TestCreateMarketDataRequest_HistoricalFuturesEnsuresFundingCompanionIdempotently|TestCreateMarketDataRequest_HistoricalFundingIsDirectAndDoesNotCreateCompanion|TestCreateMarketDataRequest_HistoricalCompanionsRemainPerSymbolAndSpotHasNone' -count=1" \
    control-marketdata/historical-funding \
    "FUNDING-DIRECT FUNDING-COMPANION FUNDING-SPOT-NONE" \
    $'--- PASS: TestCreateMarketDataRequest_HistoricalFuturesEnsuresFundingCompanionIdempotently\n--- PASS: TestCreateMarketDataRequest_HistoricalFundingIsDirectAndDoesNotCreateCompanion\n--- PASS: TestCreateMarketDataRequest_HistoricalCompanionsRemainPerSymbolAndSpotHasNone'
  run_group strategy-wallet-modes "${WORKSPACE}/strategy-service" \
    "PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest -vv tests/test_backtest_funding_wallet.py::test_futures_position_margin_wallet_matrix_tracks_each_leg_and_balance[one-way-cross] tests/test_backtest_funding_wallet.py::test_futures_position_margin_wallet_matrix_tracks_each_leg_and_balance[one-way-isolated] tests/test_backtest_funding_wallet.py::test_futures_position_margin_wallet_matrix_tracks_each_leg_and_balance[hedge-cross] tests/test_backtest_funding_wallet.py::test_futures_position_margin_wallet_matrix_tracks_each_leg_and_balance[hedge-isolated]" \
    strategy-wallet/four-modes \
    "MODE-ONEWAY-CROSS MODE-ONEWAY-ISOLATED MODE-HEDGE-CROSS MODE-HEDGE-ISOLATED" \
    $'tests/test_backtest_funding_wallet.py::test_futures_position_margin_wallet_matrix_tracks_each_leg_and_balance[one-way-cross] PASSED\ntests/test_backtest_funding_wallet.py::test_futures_position_margin_wallet_matrix_tracks_each_leg_and_balance[one-way-isolated] PASSED\ntests/test_backtest_funding_wallet.py::test_futures_position_margin_wallet_matrix_tracks_each_leg_and_balance[hedge-cross] PASSED\ntests/test_backtest_funding_wallet.py::test_futures_position_margin_wallet_matrix_tracks_each_leg_and_balance[hedge-isolated] PASSED'
  run_group strategy-spot-semantics "${WORKSPACE}/strategy-service" \
    "PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest -vv tests/test_spot_end_to_end.py::test_spot_buy_applies_actual_fill_and_bnb_commission_once_across_replays tests/test_spot_end_to_end.py::test_spot_wallet_uses_asset_codes_and_market_data_never_creates_symbol_asset tests/test_backtest_pages.py::test_spot_timeline_contains_only_klines_and_no_funding_coverage_requirement tests/test_strategy_validator.py::test_validator_rejects_strategy_leverage_for_spot_only_targets_at_assignment" \
    strategy-spot/asset-wallet-funding-leverage \
    "SPOT-ASSET-WALLET SPOT-NO-FUNDING SPOT-NO-LEVERAGE" \
    $'tests/test_spot_end_to_end.py::test_spot_buy_applies_actual_fill_and_bnb_commission_once_across_replays PASSED\ntests/test_spot_end_to_end.py::test_spot_wallet_uses_asset_codes_and_market_data_never_creates_symbol_asset PASSED\ntests/test_backtest_pages.py::test_spot_timeline_contains_only_klines_and_no_funding_coverage_requirement PASSED\ntests/test_strategy_validator.py::test_validator_rejects_strategy_leverage_for_spot_only_targets_at_assignment PASSED'
  run_group strategy-funding-gap "${WORKSPACE}/strategy-service" \
    "PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest -vv tests/test_grpc_server.py::test_backtest_incomplete_funding_coverage_is_typed_only_with_open_futures_leg tests/test_grpc_server.py::test_backtest_funding_gap_can_be_filled_and_same_run_retried" \
    strategy-backtest/funding-gap-and-retry "FUNDING-GAP FUNDING-RETRY" \
    $'tests/test_grpc_server.py::test_backtest_incomplete_funding_coverage_is_typed_only_with_open_futures_leg[True-False] PASSED\ntests/test_grpc_server.py::test_backtest_incomplete_funding_coverage_is_typed_only_with_open_futures_leg[True-None] PASSED\ntests/test_grpc_server.py::test_backtest_incomplete_funding_coverage_is_typed_only_with_open_futures_leg[False-False] PASSED\ntests/test_grpc_server.py::test_backtest_funding_gap_can_be_filled_and_same_run_retried PASSED'
  run_group strategy-three-day "${WORKSPACE}/strategy-service" \
    "PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest -vv tests/test_backtest_pages.py::test_three_day_funding_timeline_emits_every_settlement_once_across_pages tests/test_backtest_funding_wallet.py::test_three_day_funding_entries_apply_once_without_netting_hedge_details" \
    strategy-backtest/three-day-funding "FUNDING-THREE-DAY" \
    $'tests/test_backtest_pages.py::test_three_day_funding_timeline_emits_every_settlement_once_across_pages PASSED\ntests/test_backtest_funding_wallet.py::test_three_day_funding_entries_apply_once_without_netting_hedge_details PASSED'
  run_group strategy-ioc "${WORKSPACE}/strategy-service" \
    "PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest -vv tests/test_order_client.py::test_place_order_ioc_partial_expired_emits_terminal_fill_event" \
    strategy-order-client/IOC-partial-expired "ORDER-CLIENT-IOC" \
    'tests/test_order_client.py::test_place_order_ioc_partial_expired_emits_terminal_fill_event PASSED'
  run_group strategy-tif-wallets "${WORKSPACE}/strategy-service" \
    "PYTHONPATH=.:../strategy-library uv run --frozen --extra dev pytest -vv tests/test_trading_mode_wallet_matrix.py::test_spot_canonical_order_outcome_wallet_delta_matrix[full] tests/test_trading_mode_wallet_matrix.py::test_spot_canonical_order_outcome_wallet_delta_matrix[gtc-partial] tests/test_trading_mode_wallet_matrix.py::test_spot_canonical_order_outcome_wallet_delta_matrix[ioc-partial-expired] tests/test_trading_mode_wallet_matrix.py::test_spot_canonical_order_outcome_wallet_delta_matrix[fok-zero] tests/test_trading_mode_wallet_matrix.py::test_futures_canonical_order_outcome_wallet_delta_matrix[full] tests/test_trading_mode_wallet_matrix.py::test_futures_canonical_order_outcome_wallet_delta_matrix[gtc-partial] tests/test_trading_mode_wallet_matrix.py::test_futures_canonical_order_outcome_wallet_delta_matrix[ioc-partial-expired] tests/test_trading_mode_wallet_matrix.py::test_futures_canonical_order_outcome_wallet_delta_matrix[fok-zero]" \
    strategy-wallet/TIF-deltas \
    "SPOT-WALLET-FULL SPOT-WALLET-GTC-PARTIAL SPOT-WALLET-IOC-PARTIAL SPOT-WALLET-FOK-ZERO FUT-WALLET-FULL FUT-WALLET-GTC-PARTIAL FUT-WALLET-IOC-PARTIAL FUT-WALLET-FOK-ZERO" \
    $'tests/test_trading_mode_wallet_matrix.py::test_spot_canonical_order_outcome_wallet_delta_matrix[full] PASSED\ntests/test_trading_mode_wallet_matrix.py::test_spot_canonical_order_outcome_wallet_delta_matrix[gtc-partial] PASSED\ntests/test_trading_mode_wallet_matrix.py::test_spot_canonical_order_outcome_wallet_delta_matrix[ioc-partial-expired] PASSED\ntests/test_trading_mode_wallet_matrix.py::test_spot_canonical_order_outcome_wallet_delta_matrix[fok-zero] PASSED\ntests/test_trading_mode_wallet_matrix.py::test_futures_canonical_order_outcome_wallet_delta_matrix[full] PASSED\ntests/test_trading_mode_wallet_matrix.py::test_futures_canonical_order_outcome_wallet_delta_matrix[gtc-partial] PASSED\ntests/test_trading_mode_wallet_matrix.py::test_futures_canonical_order_outcome_wallet_delta_matrix[ioc-partial-expired] PASSED\ntests/test_trading_mode_wallet_matrix.py::test_futures_canonical_order_outcome_wallet_delta_matrix[fok-zero] PASSED'
fi

mkdir -p -- "$(dirname -- "${REPORT}")"
python3 - "${MANIFEST}" "${EVENTS}" "${REPORT}" "${TRADING_MATRIX_CONTRACT_TEST_ONLY:-0}" <<'PY'
from __future__ import annotations

import pathlib
import sys

manifest_path, events_path, report_path = map(pathlib.Path, sys.argv[1:4])
contract_test_only = sys.argv[4] == "1"

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
cell_errors: dict[str, list[str]] = {}

def reject(cell_id: str, message: str) -> None:
    errors.append(message)
    cell_errors.setdefault(cell_id, []).append(message)

for cell_id, status, actual, evidence in event_rows:
    if cell_id not in manifest:
        errors.append(f"unknown cell {cell_id}")
        continue
    if cell_id in events:
        reject(cell_id, f"duplicate result for {cell_id}")
        continue
    if status not in {"PASS", "FAIL"}:
        reject(cell_id, f"invalid status for {cell_id}: {status}")
    if evidence != manifest[cell_id][3]:
        reject(
            cell_id,
            f"evidence mismatch for {cell_id}: {evidence!r} != {manifest[cell_id][3]!r}",
        )
    if not contract_test_only and status == "PASS" and actual in {
        "focused hermetic test passed",
        "test command passed",
    }:
        reject(cell_id, f"generic actual value is forbidden for {cell_id}")
    events[cell_id] = (status, actual, evidence)

for cell_id in manifest:
    if cell_id not in events:
        reject(cell_id, f"missing result for {cell_id}")
    elif events[cell_id][0] != "PASS":
        reject(cell_id, f"non-PASS result for {cell_id}")

def esc(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ")

lines = [
    "# Trading Mode Matrix — 2026-08-28",
    "",
    "Hermetic Binance mock and local service tests only; no real Binance API was called.",
    "Each Actual value names the exact facts asserted by the Evidence ID; a row is PASS only after that exact test node emitted its PASS marker.",
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
    reported_errors = cell_errors.get(cell_id, [])
    if reported_errors and event is not None:
        status = "FAIL"
    error = "0 asserted mismatches" if status == "PASS" else "; ".join(reported_errors) or actual
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
