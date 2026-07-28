package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"syscall"
	"testing"

	orderv1 "github.com/hushine-tech/core-service/gen/orderv1"
	portfoliov1 "github.com/hushine-tech/core-service/gen/portfoliov1"
	strategyv1 "github.com/hushine-tech/strategy-service/gen/strategyv1"
)

func TestPreviewReadyRequiresValidBacktestContract(t *testing.T) {
	ready := func() *strategyv1.PreviewRunStrategyResponse {
		return &strategyv1.PreviewRunStrategyResponse{
			Profile:   "backtest",
			Supported: true,
			Ok:        true,
			DeclaredInputs: []*strategyv1.LiveStreamBinding{
				{Exchange: "binance", Market: "perpetual_futures", Kind: "kline", Symbol: "BTCUSDT", Interval: "1m"},
				{Exchange: "binance", Market: "perpetual_futures", Kind: "kline", Symbol: "BTCUSDT", Interval: "5m"},
				{Exchange: "binance", Market: "perpetual_futures", Kind: "kline", Symbol: "ETHUSDT", Interval: "1m"},
				{Exchange: "binance", Market: "spot", Kind: "kline", Symbol: "BTCUSDT", Interval: "1m"},
			},
		}
	}
	if !previewReady(ready(), 4) {
		t.Fatal("four distinct canonical backtest inputs must be accepted")
	}
	if previewReady(ready(), 3) {
		t.Fatal("unexpected declared input count must be rejected")
	}
	for _, tc := range []struct {
		name   string
		mutate func(*strategyv1.PreviewRunStrategyResponse)
	}{
		{name: "wrong profile", mutate: func(resp *strategyv1.PreviewRunStrategyResponse) { resp.Profile = "demo" }},
		{name: "unsupported", mutate: func(resp *strategyv1.PreviewRunStrategyResponse) { resp.Supported = false }},
		{name: "not ok", mutate: func(resp *strategyv1.PreviewRunStrategyResponse) { resp.Ok = false }},
		{name: "failure", mutate: func(resp *strategyv1.PreviewRunStrategyResponse) {
			resp.Failures = []*strategyv1.PreflightFailureProto{{}}
		}},
		{name: "no input", mutate: func(resp *strategyv1.PreviewRunStrategyResponse) { resp.DeclaredInputs = nil }},
		{name: "empty canonical field", mutate: func(resp *strategyv1.PreviewRunStrategyResponse) {
			resp.DeclaredInputs[0].Interval = ""
		}},
		{name: "duplicate canonical input", mutate: func(resp *strategyv1.PreviewRunStrategyResponse) {
			resp.DeclaredInputs[1] = resp.DeclaredInputs[0]
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			resp := ready()
			tc.mutate(resp)
			if previewReady(resp, 4) {
				t.Fatalf("previewReady accepted %+v", resp)
			}
		})
	}
	if previewReady(nil, 0) {
		t.Fatal("nil preview must be rejected")
	}
}

func TestSpotPreviewReadyRequiresDemoMixedRouteContract(t *testing.T) {
	ready := func() *strategyv1.PreviewRunStrategyResponse {
		return &strategyv1.PreviewRunStrategyResponse{
			Profile:   "demo",
			Supported: true,
			Ok:        true,
			DeclaredInputs: []*strategyv1.LiveStreamBinding{
				{Exchange: "binance", Market: "spot", Symbol: "BTCUSDT", Interval: "1m"},
				{Exchange: "binance", Market: "spot", Symbol: "ETHUSDT", Interval: "5m"},
				{Exchange: "binance", Market: "perpetual_futures", Symbol: "BTCUSDT", Interval: "1m"},
			},
			DeclaredOrderTargets: []*strategyv1.StrategyOrderTargetBinding{
				{Exchange: "binance", Market: "spot", Symbol: "BTCUSDT"},
				{Exchange: "binance", Market: "spot", Symbol: "ETHUSDT"},
			},
			RequiredRoutes: []*strategyv1.StrategyRouteBinding{
				{Exchange: "binance", Market: "spot"},
				{Exchange: "binance", Market: "perpetual_futures"},
			},
		}
	}
	if err := spotPreviewReady(ready()); err != nil {
		t.Fatalf("exact Demo mixed-route preview rejected: %v", err)
	}
	for _, tc := range []struct {
		name   string
		mutate func(*strategyv1.PreviewRunStrategyResponse)
	}{
		{name: "wrong profile", mutate: func(resp *strategyv1.PreviewRunStrategyResponse) { resp.Profile = "backtest" }},
		{name: "not ready", mutate: func(resp *strategyv1.PreviewRunStrategyResponse) { resp.Ok = false }},
		{name: "missing ETH interval", mutate: func(resp *strategyv1.PreviewRunStrategyResponse) { resp.DeclaredInputs = resp.DeclaredInputs[:1] }},
		{name: "missing Futures isolation route", mutate: func(resp *strategyv1.PreviewRunStrategyResponse) { resp.DeclaredInputs = resp.DeclaredInputs[:2] }},
		{name: "Futures order target", mutate: func(resp *strategyv1.PreviewRunStrategyResponse) {
			resp.DeclaredOrderTargets = append(resp.DeclaredOrderTargets, &strategyv1.StrategyOrderTargetBinding{Exchange: "binance", Market: "perpetual_futures", Symbol: "BTCUSDT"})
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			resp := ready()
			tc.mutate(resp)
			if err := spotPreviewReady(resp); err == nil {
				t.Fatalf("spotPreviewReady accepted %#v", resp)
			}
		})
	}
}

func TestCompareSpotDemoFactsRequiresIndependentExactEvidence(t *testing.T) {
	fixture := func() (spotDemoEvidence, []*orderv1.ExchangeOrderEntry, []*orderv1.OrderFillEntry, []*portfoliov1.ReconciliationRunEntry, spotDemoBaseline, spotDemoBaseline) {
		evidence := spotDemoEvidence{
			SchemaVersion: 1, Complete: true, UserID: 7, PortfolioID: 11, VenueID: 13, SessionID: "session-1",
			Orders: []spotEvidenceOrder{
				{Symbol: "BTCUSDT", Side: "BUY", Type: "MARKET", Status: "FILLED", OrderID: "9001", ClientOrderID: "client-btc", OrigQty: "0.00100000", ExecutedQty: "0.00100000", CumulativeQuoteQty: "50.00000000"},
				{Symbol: "ETHUSDT", Side: "SELL", Type: "MARKET", Status: "FILLED", OrderID: "9002", ClientOrderID: "client-eth", OrigQty: "0.01000000", ExecutedQty: "0.01000000", CumulativeQuoteQty: "30.00000000"},
			},
			Trades: []spotEvidenceTrade{
				{Symbol: "BTCUSDT", OrderID: "9001", TradeID: "7001", Qty: "0.00100000", Price: "50000.00000000", QuoteQty: "50.00000000", Commission: "0.00000100", CommissionAsset: "BTC"},
				{Symbol: "ETHUSDT", OrderID: "9002", TradeID: "7002", Qty: "0.01000000", Price: "3000.00000000", QuoteQty: "30.00000000", Commission: "0.03000000", CommissionAsset: "USDT"},
			},
			Balances: []spotEvidenceBalance{
				{Asset: "USDT", Free: "949.75000000", Locked: "0.00000000"},
				{Asset: "BTC", Free: "0.00100000", Locked: "0.00000000"},
				{Asset: "ETH", Free: "0.01000000", Locked: "0.00000000"},
			},
		}
		orders := []*orderv1.ExchangeOrderEntry{
			{ExchangeOrderId: "9001", ClientOrderId: "client-btc", Symbol: "BTCUSDT", Side: "BUY", Status: "FILLED", Environment: 1, Exchange: 1, Market: 1, VenueId: 13, OrigQtyDecimal: "0.001", ExecutedQtyDecimal: "0.001", CumulativeQuoteQtyDecimal: "50"},
			{ExchangeOrderId: "9002", ClientOrderId: "client-eth", Symbol: "ETHUSDT", Side: "SELL", Status: "FILLED", Environment: 1, Exchange: 1, Market: 1, VenueId: 13, OrigQtyDecimal: "0.01", ExecutedQtyDecimal: "0.01", CumulativeQuoteQtyDecimal: "30"},
		}
		fills := []*orderv1.OrderFillEntry{
			{ExchangeTradeId: "7001", ExchangeOrderId: "9001", Symbol: "BTCUSDT", Environment: 1, Exchange: 1, Market: 1, VenueId: 13, QtyDecimal: "0.001", FillPriceDecimal: "50000", QuoteQtyDecimal: "50", FeeDecimal: "0.000001", FeeAsset: "BTC"},
			{ExchangeTradeId: "7002", ExchangeOrderId: "9002", Symbol: "ETHUSDT", Environment: 1, Exchange: 1, Market: 1, VenueId: 13, QtyDecimal: "0.01", FillPriceDecimal: "3000", QuoteQtyDecimal: "30", FeeDecimal: "0.03", FeeAsset: "USDT"},
		}
		snapshot := `{"spot":{"assets":[{"asset":"USDT","free":949.75,"locked":0,"free_decimal":"949.75000000","locked_decimal":"0.00000000"},{"asset":"BTC","free":0.001,"locked":0,"free_decimal":"0.00100000","locked_decimal":"0.00000000"},{"asset":"ETH","free":0.01,"locked":0,"free_decimal":"0.01000000","locked_decimal":"0.00000000"},{"asset":"BNB","free":1,"locked":0,"free_decimal":"1.00000000","locked_decimal":"0.00000000"}]}}`
		reconciliation := []*portfoliov1.ReconciliationRunEntry{{
			SessionId: "session-1", Environment: 1, HardPass: true,
			LocalSnapshotJson: snapshot, ExchangeSnapshotJson: snapshot,
		}}
		baseline := spotDemoBaseline{
			SchemaVersion: 1, PortfolioID: 11, VenueID: 13,
			Futures: map[string]json.RawMessage{"14": json.RawMessage(`{"wallet_balance":1000}`)},
			SpotAssets: map[string]spotBalanceFact{
				"USDT": {Free: "1000", Locked: "0"}, "BTC": {Free: "0", Locked: "0"},
				"ETH": {Free: "0.02", Locked: "0"}, "BNB": {Free: "1", Locked: "0"},
			},
		}
		current := spotDemoBaseline{
			SchemaVersion: 1, PortfolioID: 11, VenueID: 13,
			Futures: map[string]json.RawMessage{"14": json.RawMessage(`{"wallet_balance":1000}`)},
			SpotAssets: map[string]spotBalanceFact{
				"USDT": {Free: "949.75", Locked: "0"}, "BTC": {Free: "0.001", Locked: "0"},
				"ETH": {Free: "0.01", Locked: "0"}, "BNB": {Free: "1", Locked: "0"},
			},
		}
		// BNB is undeclared and unchanged, but the final account evidence must
		// still include it for exact account equality.
		evidence.Balances = append(evidence.Balances, spotEvidenceBalance{Asset: "BNB", Free: "1.00000000", Locked: "0.00000000"})
		return evidence, orders, fills, reconciliation, baseline, current
	}

	evidence, orders, fills, reconciliation, baseline, current := fixture()
	if err := compareSpotDemoFacts(evidence, orders, fills, reconciliation, baseline, current); err != nil {
		t.Fatalf("valid independent evidence rejected: %v", err)
	}

	for _, tc := range []struct {
		name   string
		mutate func(*spotDemoEvidence, []*orderv1.ExchangeOrderEntry, []*orderv1.OrderFillEntry, []*portfoliov1.ReconciliationRunEntry, *spotDemoBaseline)
	}{
		{name: "executed quantity", mutate: func(_ *spotDemoEvidence, orders []*orderv1.ExchangeOrderEntry, _ []*orderv1.OrderFillEntry, _ []*portfoliov1.ReconciliationRunEntry, _ *spotDemoBaseline) {
			orders[0].ExecutedQtyDecimal = "0.002"
		}},
		{name: "cumulative quote quantity", mutate: func(_ *spotDemoEvidence, orders []*orderv1.ExchangeOrderEntry, _ []*orderv1.OrderFillEntry, _ []*portfoliov1.ReconciliationRunEntry, _ *spotDemoBaseline) {
			orders[0].CumulativeQuoteQtyDecimal = "51"
		}},
		{name: "exchange trade ID", mutate: func(_ *spotDemoEvidence, _ []*orderv1.ExchangeOrderEntry, fills []*orderv1.OrderFillEntry, _ []*portfoliov1.ReconciliationRunEntry, _ *spotDemoBaseline) {
			fills[0].ExchangeTradeId = "wrong"
		}},
		{name: "commission asset", mutate: func(_ *spotDemoEvidence, _ []*orderv1.ExchangeOrderEntry, fills []*orderv1.OrderFillEntry, _ []*portfoliov1.ReconciliationRunEntry, _ *spotDemoBaseline) {
			fills[0].FeeAsset = "USDT"
		}},
		{name: "reconciliation hard pass", mutate: func(_ *spotDemoEvidence, _ []*orderv1.ExchangeOrderEntry, _ []*orderv1.OrderFillEntry, runs []*portfoliov1.ReconciliationRunEntry, _ *spotDemoBaseline) {
			runs[0].HardPass = false
		}},
		{name: "undeclared asset", mutate: func(_ *spotDemoEvidence, _ []*orderv1.ExchangeOrderEntry, _ []*orderv1.OrderFillEntry, _ []*portfoliov1.ReconciliationRunEntry, current *spotDemoBaseline) {
			current.SpotAssets["BNB"] = spotBalanceFact{Free: "2", Locked: "0"}
		}},
		{name: "Futures wallet", mutate: func(_ *spotDemoEvidence, _ []*orderv1.ExchangeOrderEntry, _ []*orderv1.OrderFillEntry, _ []*portfoliov1.ReconciliationRunEntry, current *spotDemoBaseline) {
			current.Futures["14"] = json.RawMessage(`{"wallet_balance":999}`)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			evidence, orders, fills, reconciliation, baseline, current := fixture()
			tc.mutate(&evidence, orders, fills, reconciliation, &current)
			if err := compareSpotDemoFacts(evidence, orders, fills, reconciliation, baseline, current); err == nil {
				t.Fatal("mismatch was accepted")
			}
		})
	}
}

func TestValidateSpotStopResponseSeparatesStopOnlyAndClose(t *testing.T) {
	if err := validateSpotStopResponse("stop-only", &strategyv1.StopStrategyResponse{Stopped: true}); err != nil {
		t.Fatalf("stop-only rejected: %v", err)
	}
	closeResponse := &strategyv1.StopStrategyResponse{
		Stopped: true, OperationId: "op-1", ReconciliationRunId: "reconcile-1",
		TargetResults: []*strategyv1.StopTargetResult{
			{Exchange: 1, Market: 1, Symbol: "BTCUSDT", Status: "FILLED"},
			{Exchange: 1, Market: 1, Symbol: "ETHUSDT", Status: "NO_BALANCE"},
		},
	}
	if err := validateSpotStopResponse("stop-close", closeResponse); err != nil {
		t.Fatalf("stop-close rejected: %v", err)
	}
	closeResponse.TargetResults[1].Market = 2
	if err := validateSpotStopResponse("stop-close", closeResponse); err == nil {
		t.Fatal("Futures target was accepted in Spot stop-close response")
	}
}

func TestTerminalSessionStatusRequiresStopped(t *testing.T) {
	if !terminalSessionStatus("stopped") {
		t.Fatal("stopped must be accepted")
	}
	for _, status := range []string{"completed", "finished", "failed", "stop_failed", "recoverable"} {
		if terminalSessionStatus(status) {
			t.Errorf("%q must not satisfy a successful STOP_ACTION_STOP_ONLY assertion", status)
		}
	}
}

func TestTerminalRuntimeStatusRequiresCancelled(t *testing.T) {
	if !terminalRuntimeStatus("cancelled") {
		t.Fatal("cancelled must be accepted")
	}
	for _, status := range []string{"ended", "failed", "heartbeat_stale"} {
		if terminalRuntimeStatus(status) {
			t.Errorf("%q must not satisfy a successful EndRuntime assertion", status)
		}
	}
}

func TestCoverageDebugExecutableHonorsUVBin(t *testing.T) {
	t.Setenv("UV_BIN", " /portable/tools/uv ")
	if got := coverageDebugExecutable(); got != "/portable/tools/uv" {
		t.Fatalf("coverageDebugExecutable() = %q, want UV_BIN override", got)
	}
	t.Setenv("UV_BIN", "")
	if got := coverageDebugExecutable(); got != "uv" {
		t.Fatalf("coverageDebugExecutable() = %q, want PATH fallback", got)
	}
}

func TestRunningSessionIDsAreSafeDeterministicAndUnique(t *testing.T) {
	got := runningSessionIDs([]*portfoliov1.StrategySessionEntry{
		{SessionId: " session-b "},
		nil,
		{SessionId: "session-a"},
		{SessionId: ""},
		{SessionId: "session-b"},
	})
	want := []string{"session-a", "session-b"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("runningSessionIDs() = %q, want %q", got, want)
	}
}

func TestStageRuntimeCoverageCopiesRegularPythonShardsIntoOwnedReportRoot(t *testing.T) {
	outputRoot, runtimeRoot, reportRoot := coverageStageFixture(t, "rt-stage")
	pythonRoot := filepath.Join(runtimeRoot, "python")
	writeTestFile(t, filepath.Join(pythonRoot, ".coverage.z"), "z-shard")
	writeTestFile(t, filepath.Join(pythonRoot, ".coverage.a"), "a-shard")
	writeTestFile(t, filepath.Join(runtimeRoot, "go", "covcounters.test"), "go-data")

	var validated []string
	result, err := stageRuntimeCoverage(context.Background(), coverageStageConfig{
		OutputRoot:  outputRoot,
		RuntimeRoot: runtimeRoot,
		ReportRoot:  reportRoot,
		RuntimeID:   "rt-stage",
	}, func(_ context.Context, shard string, output io.Writer) error {
		validated = append(validated, filepath.Base(shard))
		_, _ = io.WriteString(output, "validated "+filepath.Base(shard)+"\n")
		return nil
	})
	if err != nil {
		t.Fatalf("stageRuntimeCoverage: %v", err)
	}
	wantNames := []string{".coverage.a", ".coverage.z"}
	if !reflect.DeepEqual(result.PythonShardNames, wantNames) {
		t.Fatalf("staged shard names = %q, want %q", result.PythonShardNames, wantNames)
	}
	if !reflect.DeepEqual(validated, wantNames) {
		t.Fatalf("validated shard names = %q, want %q", validated, wantNames)
	}
	for _, name := range wantNames {
		body, readErr := os.ReadFile(filepath.Join(result.PythonInputDir, name))
		if readErr != nil {
			t.Fatalf("read staged shard %s: %v", name, readErr)
		}
		want := map[string]string{".coverage.a": "a-shard", ".coverage.z": "z-shard"}[name]
		if got := string(body); got != want {
			t.Fatalf("staged shard %s = %q, want %q", name, got, want)
		}
	}
	info, err := os.Stat(reportRoot)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o700 {
		t.Fatalf("report root mode = %#o, want 0700", got)
	}
	if result.ValidationLog != filepath.Join(reportRoot, "python-data-validation-output.txt") {
		t.Fatalf("validation log = %q", result.ValidationLog)
	}
}

func TestStageRuntimeCoverageForcesOwnedDirectoriesToMode0700(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("umask is unavailable on Windows")
	}
	outputRoot, runtimeRoot, reportRoot := coverageStageFixture(t, "rt-mode")
	writeTestFile(t, filepath.Join(runtimeRoot, "python", ".coverage.valid"), "valid")
	previousMask := syscall.Umask(0o777)
	t.Cleanup(func() { syscall.Umask(previousMask) })
	result, err := stageRuntimeCoverage(context.Background(), coverageStageConfig{
		OutputRoot: outputRoot, RuntimeRoot: runtimeRoot, ReportRoot: reportRoot, RuntimeID: "rt-mode",
	}, func(context.Context, string, io.Writer) error { return nil })
	if err != nil {
		t.Fatalf("stageRuntimeCoverage: %v", err)
	}
	for _, path := range []string{filepath.Dir(reportRoot), reportRoot, result.PythonInputDir} {
		info, statErr := os.Stat(path)
		if statErr != nil {
			t.Fatal(statErr)
		}
		if got := info.Mode().Perm(); got != 0o700 {
			t.Fatalf("owned directory %s mode = %#o, want 0700", filepath.Base(path), got)
		}
	}
}

func TestStageRuntimeCoverageRejectsSymlinkAndCoverageDirectoryBeforeWritingReports(t *testing.T) {
	for _, tc := range []struct {
		name  string
		plant func(t *testing.T, runtimeRoot string)
	}{
		{
			name: "symlink",
			plant: func(t *testing.T, runtimeRoot string) {
				t.Helper()
				outside := filepath.Join(t.TempDir(), "outside")
				writeTestFile(t, outside, "canary")
				if err := os.Symlink(outside, filepath.Join(runtimeRoot, "python", ".coverage.escape")); err != nil {
					t.Fatal(err)
				}
			},
		},
		{
			name: "coverage directory",
			plant: func(t *testing.T, runtimeRoot string) {
				t.Helper()
				if err := os.Mkdir(filepath.Join(runtimeRoot, "python", ".coverage.directory"), 0o700); err != nil {
					t.Fatal(err)
				}
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			outputRoot, runtimeRoot, reportRoot := coverageStageFixture(t, "rt-unsafe")
			tc.plant(t, runtimeRoot)
			_, err := stageRuntimeCoverage(context.Background(), coverageStageConfig{
				OutputRoot: outputRoot, RuntimeRoot: runtimeRoot, ReportRoot: reportRoot, RuntimeID: "rt-unsafe",
			}, func(context.Context, string, io.Writer) error { return nil })
			if err == nil {
				t.Fatal("unsafe runtime tree was accepted")
			}
			if _, statErr := os.Lstat(reportRoot); !errors.Is(statErr, os.ErrNotExist) {
				t.Fatalf("report root was created before rejecting unsafe input: %v", statErr)
			}
		})
	}
}

func TestStageRuntimeCoverageRejectsSpecialFileRecursively(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("mkfifo is unavailable on Windows")
	}
	outputRoot, runtimeRoot, reportRoot := coverageStageFixture(t, "rt-special")
	fifo := filepath.Join(runtimeRoot, "go", "unexpected-fifo")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	_, err := stageRuntimeCoverage(context.Background(), coverageStageConfig{
		OutputRoot: outputRoot, RuntimeRoot: runtimeRoot, ReportRoot: reportRoot, RuntimeID: "rt-special",
	}, func(context.Context, string, io.Writer) error { return nil })
	if err == nil {
		t.Fatal("special file was accepted")
	}
}

func TestStageRuntimeCoverageRefusesPreplantedReportSymlinkWithoutChangingCanary(t *testing.T) {
	outputRoot, runtimeRoot, reportRoot := coverageStageFixture(t, "rt-report-link")
	writeTestFile(t, filepath.Join(runtimeRoot, "python", ".coverage.valid"), "valid")
	outside := t.TempDir()
	canary := filepath.Join(outside, "canary")
	writeTestFile(t, canary, "unchanged")
	if err := os.MkdirAll(filepath.Dir(reportRoot), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, reportRoot); err != nil {
		t.Fatal(err)
	}
	_, err := stageRuntimeCoverage(context.Background(), coverageStageConfig{
		OutputRoot: outputRoot, RuntimeRoot: runtimeRoot, ReportRoot: reportRoot, RuntimeID: "rt-report-link",
	}, func(context.Context, string, io.Writer) error { return nil })
	if err == nil {
		t.Fatal("preplanted report symlink was accepted")
	}
	body, readErr := os.ReadFile(canary)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if got := string(body); got != "unchanged" {
		t.Fatalf("outside canary = %q, want unchanged", got)
	}
}

func TestStageRuntimeCoverageFailsClosedWhenLockedValidationRejectsShard(t *testing.T) {
	outputRoot, runtimeRoot, reportRoot := coverageStageFixture(t, "rt-invalid")
	writeTestFile(t, filepath.Join(runtimeRoot, "python", ".coverage.bad"), "not sqlite")
	wantErr := errors.New("invalid coverage data")
	result, err := stageRuntimeCoverage(context.Background(), coverageStageConfig{
		OutputRoot: outputRoot, RuntimeRoot: runtimeRoot, ReportRoot: reportRoot, RuntimeID: "rt-invalid",
	}, func(_ context.Context, _ string, output io.Writer) error {
		_, _ = io.WriteString(output, "locked validator rejected shard\n")
		return wantErr
	})
	if !errors.Is(err, wantErr) {
		t.Fatalf("stageRuntimeCoverage error = %v, want validator error", err)
	}
	if len(result.PythonShardNames) != 1 || result.PythonShardNames[0] != ".coverage.bad" {
		t.Fatalf("retained staged evidence = %q", result.PythonShardNames)
	}
	body, readErr := os.ReadFile(result.ValidationLog)
	if readErr != nil {
		t.Fatalf("read validation evidence: %v", readErr)
	}
	if !strings.Contains(string(body), "locked validator rejected shard") {
		t.Fatalf("validation evidence = %q", body)
	}
}

func coverageStageFixture(t *testing.T, runtimeID string) (string, string, string) {
	t.Helper()
	outputRoot := t.TempDir()
	runtimeRoot := filepath.Join(outputRoot, "runtimes", runtimeID)
	for _, dir := range []string{filepath.Join(runtimeRoot, "go"), filepath.Join(runtimeRoot, "python")} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	reportRoot := filepath.Join(outputRoot, "smoke-reports", runtimeID)
	return outputRoot, runtimeRoot, reportRoot
}

func writeTestFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
}
