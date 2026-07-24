package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"math/big"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"

	controlpanelv1 "github.com/hushine-tech/control-panel-service/gen/controlpanelv1"
	orderv1 "github.com/hushine-tech/core-service/gen/orderv1"
	portfoliov1 "github.com/hushine-tech/core-service/gen/portfoliov1"
	strategyv1 "github.com/hushine-tech/strategy-service/gen/strategyv1"
	"golang.org/x/sys/unix"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/encoding/protojson"
)

func main() {
	action := flag.String("action", "", "preview, spot-preview, baseline, run, verify, expect-end-blocked, stop, stop-only, stop-close, stop-running, end, or stage-coverage")
	controlPanelAddr := flag.String("control-panel-addr", "127.0.0.1:50054", "control-panel gRPC address")
	portfolioAddr := flag.String("portfolio-addr", "127.0.0.1:50051", "portfolio.v1 gRPC address")
	userID := flag.Int64("user", 0, "runtime owner user ID")
	runtimeID := flag.String("runtime", "", "runtime ID")
	outputRoot := flag.String("output-root", "", "trusted hosted coverage output root")
	runtimeRoot := flag.String("runtime-root", "", "stopped container's runtime coverage mount")
	reportRoot := flag.String("report-root", "", "operator-owned host-only report root")
	strategyRoot := flag.String("strategy-root", "", "strategy-service source root for locked coverage validation")
	portfolioID := flag.Int64("portfolio", 0, "portfolio ID; zero selects the first owned portfolio with an active strategy")
	venueID := flag.Int64("venue", 0, "run-owned Binance Spot Demo venue ID")
	sessionID := flag.String("session", "", "strategy session ID")
	evidenceFile := flag.String("evidence-file", "", "validated exchange evidence JSON")
	baselineFile := flag.String("baseline-file", "", "pre-run portfolio baseline JSON")
	operationID := flag.String("operation-id", "", "idempotent stop operation ID")
	startTimeMs := flag.Int64("start-time-ms", 1780272000000, "backtest start time")
	endTimeMs := flag.Int64("end-time-ms", 1783728000000, "backtest end time")
	expectedInputCount := flag.Int("expected-input-count", 4, "exact declared input count; zero accepts any positive count")
	timeout := flag.Duration("timeout", 30*time.Second, "RPC timeout")
	flag.Parse()

	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()
	if strings.TrimSpace(*action) == "stage-coverage" {
		if strings.TrimSpace(*runtimeID) == "" {
			fatalf("required for stage-coverage: -runtime")
		}
		if err := requireTrustedDirectory(*strategyRoot); err != nil {
			fatalf("stage runtime coverage: invalid strategy root")
		}
		result, err := stageRuntimeCoverage(ctx, coverageStageConfig{
			OutputRoot:  *outputRoot,
			RuntimeRoot: *runtimeRoot,
			ReportRoot:  *reportRoot,
			RuntimeID:   strings.TrimSpace(*runtimeID),
		}, lockedCoverageDebugRunner(*strategyRoot))
		if err != nil {
			fatalf("stage runtime coverage: %v", err)
		}
		fmt.Printf(
			"report_root=%s python_input_dir=%s validation_log=%s shard_count=%d\n",
			*reportRoot,
			result.PythonInputDir,
			result.ValidationLog,
			len(result.PythonShardNames),
		)
		return
	}
	if *userID <= 0 || strings.TrimSpace(*runtimeID) == "" {
		fatalf("required: -user and -runtime")
	}

	controlConn, err := grpc.NewClient(*controlPanelAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		fatalRPC("dial control-panel", err)
	}
	defer controlConn.Close()
	controlClient := controlpanelv1.NewControlPanelServiceClient(controlConn)

	switch strings.TrimSpace(*action) {
	case "preview":
		selected := selectPortfolio(ctx, *portfolioAddr, *userID, *portfolioID)
		resp, err := controlClient.PreviewRunStrategy(ctx, &strategyv1.PreviewRunStrategyRequest{
			PortfolioId: selected,
			UserId:      *userID,
			RuntimeId:   strings.TrimSpace(*runtimeID),
			StartTimeMs: *startTimeMs,
			EndTimeMs:   *endTimeMs,
		})
		if err != nil {
			fatalRPC("PreviewRunStrategy", err)
		}
		if !previewReady(resp, *expectedInputCount) {
			fatalf(
				"PreviewRunStrategy preflight was not ready: profile=%s supported=%t ok=%t failure_count=%d declared_input_count=%d expected_input_count=%d",
				resp.GetProfile(),
				resp.GetSupported(),
				resp.GetOk(),
				len(resp.GetFailures()),
				len(resp.GetDeclaredInputs()),
				*expectedInputCount,
			)
		}
		fmt.Printf(
			"portfolio_id=%d profile=%s supported=%t ok=%t failure_count=%d declared_input_count=%d\n",
			selected,
			resp.GetProfile(),
			resp.GetSupported(),
			resp.GetOk(),
			len(resp.GetFailures()),
			len(resp.GetDeclaredInputs()),
		)
	case "spot-preview":
		selected := selectPortfolio(ctx, *portfolioAddr, *userID, *portfolioID)
		resp, err := controlClient.PreviewRunStrategy(ctx, &strategyv1.PreviewRunStrategyRequest{
			PortfolioId: selected,
			UserId:      *userID,
			RuntimeId:   strings.TrimSpace(*runtimeID),
		})
		if err != nil {
			fatalRPC("PreviewRunStrategy", err)
		}
		if err := spotPreviewReady(resp); err != nil {
			fatalf("Spot Demo preview contract failed: %v", err)
		}
		fmt.Printf(
			"portfolio_id=%d profile=%s supported=true ok=true input_count=%d target_count=%d route_count=%d\n",
			selected,
			resp.GetProfile(),
			len(resp.GetDeclaredInputs()),
			len(resp.GetDeclaredOrderTargets()),
			len(resp.GetRequiredRoutes()),
		)
	case "baseline":
		selected := selectPortfolio(ctx, *portfolioAddr, *userID, *portfolioID)
		if *venueID <= 0 {
			fatalf("required for baseline: -venue")
		}
		baseline, err := captureSpotBaseline(ctx, *portfolioAddr, *userID, selected, *venueID)
		if err != nil {
			fatalf("capture Spot Demo baseline: %v", err)
		}
		if err := json.NewEncoder(os.Stdout).Encode(baseline); err != nil {
			fatalf("encode Spot Demo baseline")
		}
	case "run":
		selected := selectPortfolio(ctx, *portfolioAddr, *userID, *portfolioID)
		resp, err := controlClient.RunStrategy(ctx, &strategyv1.RunStrategyRequest{
			PortfolioId: selected,
			UserId:      *userID,
			RuntimeId:   strings.TrimSpace(*runtimeID),
			Interval:    "1m",
			StartTimeMs: *startTimeMs,
			EndTimeMs:   *endTimeMs,
		})
		if err != nil {
			fatalRPC("RunStrategy", err)
		}
		if strings.TrimSpace(resp.GetSessionId()) == "" {
			fatalf("RunStrategy returned an empty session_id")
		}
		fmt.Printf("portfolio_id=%d session_id=%s\n", selected, resp.GetSessionId())
	case "verify":
		selected := selectPortfolio(ctx, *portfolioAddr, *userID, *portfolioID)
		if *venueID <= 0 || strings.TrimSpace(*sessionID) == "" || strings.TrimSpace(*evidenceFile) == "" || strings.TrimSpace(*baselineFile) == "" {
			fatalf("required for verify: -venue, -session, -evidence-file, and -baseline-file")
		}
		if err := verifySpotDemo(
			ctx,
			*portfolioAddr,
			*userID,
			selected,
			*venueID,
			strings.TrimSpace(*sessionID),
			strings.TrimSpace(*evidenceFile),
			strings.TrimSpace(*baselineFile),
		); err != nil {
			fatalf("Spot Demo evidence verification failed: %v", err)
		}
		fmt.Printf("spot_demo_verified=true portfolio_id=%d venue_id=%d session_id=%s\n", selected, *venueID, strings.TrimSpace(*sessionID))
	case "expect-end-blocked":
		_, err := controlClient.EndRuntime(ctx, &controlpanelv1.EndRuntimeRequest{
			UserId:    *userID,
			RuntimeId: strings.TrimSpace(*runtimeID),
		})
		if err == nil {
			fatalf("EndRuntime unexpectedly accepted an active session")
		}
		if grpcStatus, ok := status.FromError(err); !ok || grpcStatus.Code() != codes.AlreadyExists {
			fatalRPC("EndRuntime active-session guard", err)
		}
		fmt.Println("end_runtime_active_session=blocked code=AlreadyExists")
	case "stop":
		if strings.TrimSpace(*sessionID) == "" {
			fatalf("required for stop: -session")
		}
		resp, err := controlClient.StopStrategy(ctx, &strategyv1.StopStrategyRequest{
			SessionId:  strings.TrimSpace(*sessionID),
			StopAction: strategyv1.StopAction_STOP_ACTION_STOP_ONLY,
			UserId:     *userID,
			RuntimeId:  strings.TrimSpace(*runtimeID),
		})
		if err != nil {
			fatalRPC("StopStrategy", err)
		}
		if !resp.GetStopped() {
			fatalf("StopStrategy returned stopped=false")
		}
		terminal := waitSessionTerminal(ctx, *portfolioAddr, *userID, strings.TrimSpace(*sessionID))
		fmt.Printf("session_id=%s status=%s stopped=true\n", strings.TrimSpace(*sessionID), terminal)
	case "stop-only", "stop-close":
		if strings.TrimSpace(*sessionID) == "" {
			fatalf("required for Spot stop: -session")
		}
		stopAction := strategyv1.StopAction_STOP_ACTION_STOP_ONLY
		if strings.TrimSpace(*action) == "stop-close" {
			stopAction = strategyv1.StopAction_STOP_ACTION_STOP_AND_CLOSE_POSITIONS
			if strings.TrimSpace(*operationID) == "" {
				fatalf("required for stop-close: -operation-id")
			}
		}
		resp, err := controlClient.StopStrategy(ctx, &strategyv1.StopStrategyRequest{
			SessionId:   strings.TrimSpace(*sessionID),
			StopAction:  stopAction,
			OperationId: strings.TrimSpace(*operationID),
			UserId:      *userID,
			RuntimeId:   strings.TrimSpace(*runtimeID),
		})
		if err != nil {
			fatalRPC("StopStrategy", err)
		}
		if err := validateSpotStopResponse(strings.TrimSpace(*action), resp); err != nil {
			fatalf("Spot stop contract failed: %v", err)
		}
		terminal := waitSessionTerminal(ctx, *portfolioAddr, *userID, strings.TrimSpace(*sessionID))
		fmt.Printf("session_id=%s status=%s stopped=true action=%s reconciliation_run_id=%s\n", strings.TrimSpace(*sessionID), terminal, strings.TrimSpace(*action), resp.GetReconciliationRunId())
	case "stop-running":
		count := stopRunningSessions(ctx, *portfolioAddr, *userID, strings.TrimSpace(*runtimeID), controlClient)
		fmt.Printf("runtime_id=%s running_sessions_stopped=%d\n", strings.TrimSpace(*runtimeID), count)
	case "end":
		resp, err := controlClient.EndRuntime(ctx, &controlpanelv1.EndRuntimeRequest{
			UserId:    *userID,
			RuntimeId: strings.TrimSpace(*runtimeID),
		})
		if err != nil {
			fatalRPC("EndRuntime", err)
		}
		runtime := resp.GetRuntime()
		if runtime == nil {
			fatalf("EndRuntime returned no runtime")
		}
		final, err := controlClient.GetRuntime(ctx, &controlpanelv1.GetRuntimeRequest{
			UserId:    *userID,
			RuntimeId: strings.TrimSpace(*runtimeID),
		})
		if err != nil {
			fatalRPC("GetRuntime after EndRuntime", err)
		}
		runtime = final.GetRuntime()
		if runtime == nil {
			fatalf("GetRuntime after EndRuntime returned no runtime")
		}
		if runtime.GetRuntimeId() != strings.TrimSpace(*runtimeID) || runtime.GetSource() != "hosted" || !terminalRuntimeStatus(runtime.GetStatus()) || runtime.GetCleanupStatus() != "succeeded" {
			fatalf(
				"EndRuntime returned unexpected state: runtime_id=%s source=%s cleanup_status=%s",
				runtime.GetRuntimeId(),
				runtime.GetSource(),
				runtime.GetCleanupStatus(),
			)
		}
		fmt.Printf(
			"runtime_id=%s status=%s source=%s cleanup_status=%s\n",
			runtime.GetRuntimeId(),
			runtime.GetStatus(),
			runtime.GetSource(),
			runtime.GetCleanupStatus(),
		)
	default:
		fatalf("-action must be preview, spot-preview, baseline, run, verify, expect-end-blocked, stop, stop-only, stop-close, stop-running, end, or stage-coverage")
	}
}

func spotPreviewReady(resp *strategyv1.PreviewRunStrategyResponse) error {
	// profile == "demo" is part of the acceptance identity; Backtest/Live
	// previews cannot satisfy this gate.
	if resp == nil || resp.GetProfile() != "demo" || !resp.GetSupported() || !resp.GetOk() || len(resp.GetFailures()) != 0 {
		return fmt.Errorf("profile is not a ready Demo profile")
	}
	inputs := make(map[string]struct{}, len(resp.GetDeclaredInputs()))
	for _, input := range resp.GetDeclaredInputs() {
		if input == nil {
			return fmt.Errorf("declared input is nil")
		}
		key := strings.Join([]string{
			strings.ToLower(strings.TrimSpace(input.GetExchange())),
			strings.ToLower(strings.TrimSpace(input.GetMarket())),
			strings.ToUpper(strings.TrimSpace(input.GetSymbol())),
			strings.ToLower(strings.TrimSpace(input.GetInterval())),
		}, "/")
		inputs[key] = struct{}{}
	}
	wantInputs := map[string]struct{}{
		"binance/spot/BTCUSDT/1m":              {},
		"binance/spot/ETHUSDT/5m":              {},
		"binance/perpetual_futures/BTCUSDT/1m": {},
	}
	if !sameStringSet(inputs, wantInputs) {
		return fmt.Errorf("declared inputs must be the deterministic two-symbol/two-interval mixed-route set")
	}
	targets := make(map[string]struct{}, len(resp.GetDeclaredOrderTargets()))
	for _, target := range resp.GetDeclaredOrderTargets() {
		if target == nil {
			return fmt.Errorf("declared order target is nil")
		}
		key := strings.Join([]string{
			strings.ToLower(strings.TrimSpace(target.GetExchange())),
			strings.ToLower(strings.TrimSpace(target.GetMarket())),
			strings.ToUpper(strings.TrimSpace(target.GetSymbol())),
		}, "/")
		targets[key] = struct{}{}
	}
	wantTargets := map[string]struct{}{
		"binance/spot/BTCUSDT": {},
		"binance/spot/ETHUSDT": {},
	}
	if !sameStringSet(targets, wantTargets) {
		return fmt.Errorf("declared order targets must be Spot-only BTCUSDT and ETHUSDT")
	}
	routes := make(map[string]struct{}, len(resp.GetRequiredRoutes()))
	for _, route := range resp.GetRequiredRoutes() {
		if route == nil {
			return fmt.Errorf("required route is nil")
		}
		routes[strings.ToLower(strings.TrimSpace(route.GetExchange()))+"/"+strings.ToLower(strings.TrimSpace(route.GetMarket()))] = struct{}{}
	}
	wantRoutes := map[string]struct{}{
		"binance/spot":              {},
		"binance/perpetual_futures": {},
	}
	if !sameStringSet(routes, wantRoutes) {
		return fmt.Errorf("required routes must preserve same-symbol Spot/Futures isolation")
	}
	return nil
}

func sameStringSet(got, want map[string]struct{}) bool {
	if len(got) != len(want) {
		return false
	}
	for key := range want {
		if _, ok := got[key]; !ok {
			return false
		}
	}
	return true
}

type spotDemoEvidence struct {
	SchemaVersion          int                   `json:"schema_version"`
	Complete               bool                  `json:"complete"`
	RunID                  string                `json:"run_id"`
	UserID                 int64                 `json:"user_id"`
	PortfolioID            int64                 `json:"portfolio_id"`
	VenueID                int64                 `json:"venue_id"`
	SessionID              string                `json:"session_id"`
	CaptureStartedAt       string                `json:"capture_started_at"`
	CaptureCompletedAt     string                `json:"capture_completed_at"`
	Subscription           json.RawMessage       `json:"subscription"`
	Orders                 []spotEvidenceOrder   `json:"orders"`
	Trades                 []spotEvidenceTrade   `json:"trades"`
	Balances               []spotEvidenceBalance `json:"balances"`
	RequestedEndpoints     json.RawMessage       `json:"requested_endpoints"`
	CanonicalPayloadSHA256 string                `json:"canonical_payload_sha256"`
}

type spotEvidenceOrder struct {
	Symbol             string `json:"symbol"`
	Side               string `json:"side"`
	Type               string `json:"type"`
	Status             string `json:"status"`
	OrderID            string `json:"orderId"`
	ClientOrderID      string `json:"clientOrderId"`
	OrigQty            string `json:"origQty"`
	ExecutedQty        string `json:"executedQty"`
	CumulativeQuoteQty string `json:"cummulativeQuoteQty"`
}

type spotEvidenceTrade struct {
	Symbol          string `json:"symbol"`
	OrderID         string `json:"orderId"`
	TradeID         string `json:"id"`
	Qty             string `json:"qty"`
	Price           string `json:"price"`
	QuoteQty        string `json:"quoteQty"`
	Commission      string `json:"commission"`
	CommissionAsset string `json:"commissionAsset"`
	Time            string `json:"time"`
}

type spotEvidenceBalance struct {
	Asset  string `json:"asset"`
	Free   string `json:"free"`
	Locked string `json:"locked"`
}

type spotBalanceFact struct {
	Free   string `json:"free"`
	Locked string `json:"locked"`
}

type spotDemoBaseline struct {
	SchemaVersion int                        `json:"schema_version"`
	PortfolioID   int64                      `json:"portfolio_id"`
	VenueID       int64                      `json:"venue_id"`
	Futures       map[string]json.RawMessage `json:"futures"`
	SpotAssets    map[string]spotBalanceFact `json:"spot_assets"`
}

type reconciliationSnapshot struct {
	Spot struct {
		Assets []struct {
			Asset         string  `json:"asset"`
			Free          float64 `json:"free"`
			Locked        float64 `json:"locked"`
			FreeDecimal   string  `json:"free_decimal"`
			LockedDecimal string  `json:"locked_decimal"`
		} `json:"assets"`
	} `json:"spot"`
}

func captureSpotBaseline(ctx context.Context, addr string, userID, portfolioID, venueID int64) (spotDemoBaseline, error) {
	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return spotDemoBaseline{}, fmt.Errorf("dial portfolio service")
	}
	defer conn.Close()
	client := portfoliov1.NewPortfolioServiceClient(conn)
	snapshot, err := loadSpotAcceptanceSnapshot(ctx, client, userID, portfolioID)
	if err != nil {
		return spotDemoBaseline{}, err
	}
	baseline, err := baselineFromPortfolioSnapshot(snapshot, portfolioID, venueID)
	if err != nil {
		return spotDemoBaseline{}, err
	}
	return baseline, nil
}

func loadSpotAcceptanceSnapshot(
	ctx context.Context,
	client portfoliov1.PortfolioServiceClient,
	userID, portfolioID int64,
) (*portfoliov1.PortfolioSnapshot, error) {
	resp, err := client.GetPortfolioSnapshot(ctx, &portfoliov1.GetPortfolioSnapshotRequest{
		PortfolioId: portfolioID,
		UserId:      userID,
		RequiredSymbols: []*portfoliov1.RequiredSymbol{
			{Exchange: 1, Market: 1, Symbol: "BTCUSDT", OrderTarget: true, RequiredOrderTypes: []string{"MARKET"}},
			{Exchange: 1, Market: 1, Symbol: "ETHUSDT", OrderTarget: true, RequiredOrderTypes: []string{"MARKET"}},
			{Exchange: 1, Market: 2, Symbol: "BTCUSDT"},
		},
	})
	if err != nil {
		return nil, fmt.Errorf("get portfolio snapshot: code=%s", status.Code(err))
	}
	snapshot := resp.GetSnapshot()
	if snapshot == nil || snapshot.GetPortfolioId() != portfolioID || (snapshot.GetUserId() != 0 && snapshot.GetUserId() != userID) {
		return nil, fmt.Errorf("portfolio snapshot identity mismatch")
	}
	return snapshot, nil
}

func baselineFromPortfolioSnapshot(snapshot *portfoliov1.PortfolioSnapshot, portfolioID, venueID int64) (spotDemoBaseline, error) {
	baseline := spotDemoBaseline{
		SchemaVersion: 1,
		PortfolioID:   portfolioID,
		VenueID:       venueID,
		Futures:       make(map[string]json.RawMessage),
		SpotAssets:    make(map[string]spotBalanceFact),
	}
	spotFound := false
	for _, venue := range snapshot.GetVenues() {
		if venue == nil || venue.GetExchange() != 1 || venue.GetEnvironment() != 1 {
			continue
		}
		switch venue.GetMarket() {
		case 1:
			if venue.GetVenueId() != venueID {
				continue
			}
			spotFound = true
			for _, asset := range venue.GetWallet().GetSpot().GetAssets() {
				if asset == nil {
					return spotDemoBaseline{}, fmt.Errorf("Spot baseline contains nil asset")
				}
				code := strings.ToUpper(strings.TrimSpace(asset.GetAsset()))
				if code == "" || code == "BTCUSDT" || code == "ETHUSDT" {
					return spotDemoBaseline{}, fmt.Errorf("Spot baseline contains pseudo or empty asset")
				}
				if _, duplicate := baseline.SpotAssets[code]; duplicate {
					return spotDemoBaseline{}, fmt.Errorf("Spot baseline contains duplicate asset")
				}
				baseline.SpotAssets[code] = spotBalanceFact{
					Free:   decimalOrFloat(asset.GetFreeDecimal(), asset.GetFree()),
					Locked: decimalOrFloat(asset.GetLockedDecimal(), asset.GetLocked()),
				}
			}
		case 2:
			wallet := venue.GetWallet().GetFutures()
			if wallet == nil {
				return spotDemoBaseline{}, fmt.Errorf("Futures wallet is missing")
			}
			encoded, err := (protojson.MarshalOptions{UseProtoNames: true, EmitUnpopulated: true}).Marshal(wallet)
			if err != nil {
				return spotDemoBaseline{}, fmt.Errorf("encode Futures wallet")
			}
			baseline.Futures[strconv.FormatInt(venue.GetVenueId(), 10)] = append(json.RawMessage(nil), encoded...)
		}
	}
	if !spotFound {
		return spotDemoBaseline{}, fmt.Errorf("run-owned Binance Spot Demo venue is missing")
	}
	if len(baseline.Futures) == 0 {
		return spotDemoBaseline{}, fmt.Errorf("pre-recorded Futures route snapshot is missing")
	}
	return baseline, nil
}

func decimalOrFloat(exact string, display float64) string {
	exact = strings.TrimSpace(exact)
	if exact != "" {
		return exact
	}
	return strconv.FormatFloat(display, 'g', -1, 64)
}

func readStrictJSON(path string, out any) error {
	path = strings.TrimSpace(path)
	if !filepath.IsAbs(path) {
		return fmt.Errorf("JSON evidence path must be absolute")
	}
	info, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("read JSON evidence metadata")
	}
	if !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || info.Size() <= 0 || info.Size() > 2*1024*1024 {
		return fmt.Errorf("JSON evidence file is unsafe")
	}
	file, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("open JSON evidence")
	}
	defer file.Close()
	opened, err := file.Stat()
	if err != nil || !os.SameFile(info, opened) {
		return fmt.Errorf("JSON evidence changed while opening")
	}
	body, err := io.ReadAll(io.LimitReader(file, 2*1024*1024+1))
	if err != nil || len(body) > 2*1024*1024 {
		return fmt.Errorf("read JSON evidence")
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(out); err != nil {
		return fmt.Errorf("decode JSON evidence")
	}
	if decoder.Decode(&struct{}{}) != io.EOF {
		return fmt.Errorf("JSON evidence has trailing content")
	}
	return nil
}

func verifySpotDemo(
	ctx context.Context,
	addr string,
	userID, portfolioID, venueID int64,
	sessionID, evidencePath, baselinePath string,
) error {
	var evidence spotDemoEvidence
	if err := readStrictJSON(evidencePath, &evidence); err != nil {
		return err
	}
	if evidence.SchemaVersion != 1 || !evidence.Complete || evidence.UserID != userID || evidence.PortfolioID != portfolioID || evidence.VenueID != venueID || evidence.SessionID != sessionID {
		return fmt.Errorf("exchange evidence identity mismatch")
	}
	var baseline spotDemoBaseline
	if err := readStrictJSON(baselinePath, &baseline); err != nil {
		return err
	}
	if baseline.SchemaVersion != 1 || baseline.PortfolioID != portfolioID || baseline.VenueID != venueID {
		return fmt.Errorf("baseline identity mismatch")
	}

	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return fmt.Errorf("dial core services")
	}
	defer conn.Close()
	orderClient := orderv1.NewOrderServiceClient(conn)
	portfolioClient := portfoliov1.NewPortfolioServiceClient(conn)
	var lastErr error
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	for {
		orders, err := orderClient.QueryOrders(ctx, &orderv1.QueryOrdersRequest{
			PortfolioId: portfolioID, SessionId: sessionID, UserId: userID, Limit: 200,
		})
		if err != nil {
			return fmt.Errorf("query core orders: code=%s", status.Code(err))
		}
		fills, err := orderClient.QueryOrderFills(ctx, &orderv1.QueryOrderFillsRequest{
			PortfolioId: portfolioID, SessionId: sessionID, UserId: userID, Limit: 200,
		})
		if err != nil {
			return fmt.Errorf("query core fills: code=%s", status.Code(err))
		}
		reconciliation, err := portfolioClient.ListReconciliationRuns(ctx, &portfoliov1.ListReconciliationRunsRequest{
			SessionId: sessionID, UserId: userID, Limit: 200,
		})
		if err != nil {
			return fmt.Errorf("query reconciliation runs: code=%s", status.Code(err))
		}
		currentSnapshot, err := loadSpotAcceptanceSnapshot(ctx, portfolioClient, userID, portfolioID)
		if err != nil {
			return err
		}
		current, err := baselineFromPortfolioSnapshot(currentSnapshot, portfolioID, venueID)
		if err != nil {
			return err
		}
		lastErr = compareSpotDemoFacts(evidence, orders.GetOrders(), fills.GetFills(), reconciliation.GetItems(), baseline, current)
		if lastErr == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("verification deadline reached: %w", lastErr)
		case <-ticker.C:
		}
	}
}

func compareSpotDemoFacts(
	evidence spotDemoEvidence,
	orders []*orderv1.ExchangeOrderEntry,
	fills []*orderv1.OrderFillEntry,
	reconciliation []*portfoliov1.ReconciliationRunEntry,
	baseline, current spotDemoBaseline,
) error {
	evidenceOrders := make(map[string]spotEvidenceOrder, len(evidence.Orders))
	for _, item := range evidence.Orders {
		if item.OrderID == "" {
			return fmt.Errorf("exchange order identity is empty")
		}
		evidenceOrders[item.OrderID] = item
	}
	symbols := make(map[string]struct{})
	sides := make(map[string]struct{})
	matchedOrders := 0
	for _, order := range orders {
		if order == nil {
			continue
		}
		if order.GetExchange() != 1 || order.GetMarket() != 1 || order.GetEnvironment() != 1 || order.GetVenueId() != evidence.VenueID {
			return fmt.Errorf("core order escaped the run-owned Binance Spot Demo route")
		}
		exchangeOrder, ok := evidenceOrders[order.GetExchangeOrderId()]
		if !ok {
			return fmt.Errorf("exchange order identity is missing from raw evidence")
		}
		if exchangeOrder.Symbol != order.GetSymbol() || exchangeOrder.Side != order.GetSide() || exchangeOrder.Status != order.GetStatus() || exchangeOrder.ClientOrderID != order.GetClientOrderId() {
			return fmt.Errorf("core and exchange order identity/status mismatch")
		}
		if !decimalEqual(exchangeOrder.OrigQty, order.GetOrigQtyDecimal()) {
			return fmt.Errorf("order original quantity mismatch")
		}
		if !decimalEqual(exchangeOrder.ExecutedQty, order.GetExecutedQtyDecimal()) {
			return fmt.Errorf("order executed quantity mismatch")
		}
		if !decimalEqual(exchangeOrder.CumulativeQuoteQty, order.GetCumulativeQuoteQtyDecimal()) {
			return fmt.Errorf("order cumulative quote quantity mismatch")
		}
		symbols[order.GetSymbol()] = struct{}{}
		sides[order.GetSide()] = struct{}{}
		matchedOrders++
	}
	if matchedOrders < 2 || !sameStringSet(symbols, map[string]struct{}{"BTCUSDT": {}, "ETHUSDT": {}}) {
		return fmt.Errorf("core orders do not cover both deterministic Spot symbols")
	}
	if _, buy := sides["BUY"]; !buy {
		return fmt.Errorf("core Spot BUY order is missing")
	}
	if _, sell := sides["SELL"]; !sell {
		return fmt.Errorf("core Spot SELL order is missing")
	}

	evidenceTrades := make(map[string]spotEvidenceTrade, len(evidence.Trades))
	for _, item := range evidence.Trades {
		if item.TradeID == "" {
			return fmt.Errorf("exchange trade ID is empty")
		}
		evidenceTrades[item.TradeID] = item
	}
	fillSymbols := make(map[string]struct{})
	matchedFills := 0
	for _, fill := range fills {
		if fill == nil {
			continue
		}
		if fill.GetExchange() != 1 || fill.GetMarket() != 1 || fill.GetEnvironment() != 1 || fill.GetVenueId() != evidence.VenueID {
			return fmt.Errorf("core fill escaped the run-owned Binance Spot Demo route")
		}
		exchangeTrade, ok := evidenceTrades[fill.GetExchangeTradeId()]
		if !ok {
			return fmt.Errorf("exchange trade ID is missing from raw evidence")
		}
		if exchangeTrade.OrderID != fill.GetExchangeOrderId() || exchangeTrade.Symbol != fill.GetSymbol() {
			return fmt.Errorf("core and exchange trade identity mismatch")
		}
		if !decimalEqual(exchangeTrade.Qty, fill.GetQtyDecimal()) || !decimalEqual(exchangeTrade.Price, fill.GetFillPriceDecimal()) || !decimalEqual(exchangeTrade.QuoteQty, fill.GetQuoteQtyDecimal()) {
			return fmt.Errorf("fill quantity, price, or quote quantity mismatch")
		}
		if !decimalEqual(exchangeTrade.Commission, fill.GetFeeDecimal()) {
			return fmt.Errorf("fill commission amount mismatch")
		}
		if exchangeTrade.CommissionAsset != fill.GetFeeAsset() {
			return fmt.Errorf("fill commission asset mismatch")
		}
		fillSymbols[fill.GetSymbol()] = struct{}{}
		matchedFills++
	}
	if matchedFills < 2 || !sameStringSet(fillSymbols, map[string]struct{}{"BTCUSDT": {}, "ETHUSDT": {}}) {
		return fmt.Errorf("core fills do not cover both deterministic Spot symbols")
	}

	evidenceBalances, err := evidenceBalanceFacts(evidence.Balances)
	if err != nil {
		return err
	}
	if err := compareBalanceFacts(evidenceBalances, current.SpotAssets); err != nil {
		return fmt.Errorf("final account equality failed: %w", err)
	}
	reconciliationMatched := false
	for _, run := range reconciliation {
		if run == nil || run.GetEnvironment() != 1 || !run.GetHardPass() {
			continue
		}
		local, localErr := balancesFromReconciliationJSON(run.GetLocalSnapshotJson())
		exchange, exchangeErr := balancesFromReconciliationJSON(run.GetExchangeSnapshotJson())
		if localErr != nil || exchangeErr != nil {
			continue
		}
		if compareBalanceFacts(evidenceBalances, local) == nil && compareBalanceFacts(evidenceBalances, exchange) == nil {
			reconciliationMatched = true
			break
		}
	}
	if !reconciliationMatched {
		return fmt.Errorf("reconciliation hard pass does not match exchange and worker wallet")
	}
	if err := compareUnchangedRoutes(evidence, baseline, current); err != nil {
		return err
	}
	return nil
}

func decimalEqual(left, right string) bool {
	leftRat, leftOK := new(big.Rat).SetString(strings.TrimSpace(left))
	rightRat, rightOK := new(big.Rat).SetString(strings.TrimSpace(right))
	return leftOK && rightOK && leftRat.Cmp(rightRat) == 0
}

func evidenceBalanceFacts(items []spotEvidenceBalance) (map[string]spotBalanceFact, error) {
	result := make(map[string]spotBalanceFact, len(items))
	for _, item := range items {
		asset := strings.ToUpper(strings.TrimSpace(item.Asset))
		if asset == "" || asset == "BTCUSDT" || asset == "ETHUSDT" {
			return nil, fmt.Errorf("exchange evidence contains pseudo or empty asset")
		}
		if _, exists := result[asset]; exists {
			return nil, fmt.Errorf("exchange evidence contains duplicate asset")
		}
		if _, ok := new(big.Rat).SetString(item.Free); !ok {
			return nil, fmt.Errorf("exchange free balance is invalid")
		}
		if _, ok := new(big.Rat).SetString(item.Locked); !ok {
			return nil, fmt.Errorf("exchange locked balance is invalid")
		}
		result[asset] = spotBalanceFact{Free: item.Free, Locked: item.Locked}
	}
	return result, nil
}

func balancesFromReconciliationJSON(raw string) (map[string]spotBalanceFact, error) {
	var snapshot reconciliationSnapshot
	decoder := json.NewDecoder(strings.NewReader(raw))
	if err := decoder.Decode(&snapshot); err != nil {
		return nil, err
	}
	result := make(map[string]spotBalanceFact, len(snapshot.Spot.Assets))
	for _, asset := range snapshot.Spot.Assets {
		code := strings.ToUpper(strings.TrimSpace(asset.Asset))
		if code == "" || code == "BTCUSDT" || code == "ETHUSDT" {
			return nil, fmt.Errorf("reconciliation contains pseudo or empty asset")
		}
		if _, duplicate := result[code]; duplicate {
			return nil, fmt.Errorf("reconciliation contains duplicate asset")
		}
		result[code] = spotBalanceFact{
			Free:   decimalOrFloat(asset.FreeDecimal, asset.Free),
			Locked: decimalOrFloat(asset.LockedDecimal, asset.Locked),
		}
	}
	return result, nil
}

func compareBalanceFacts(expected, actual map[string]spotBalanceFact) error {
	if len(expected) != len(actual) {
		return fmt.Errorf("asset set mismatch")
	}
	for asset, want := range expected {
		got, ok := actual[asset]
		if !ok {
			return fmt.Errorf("asset %s is missing", asset)
		}
		if !decimalEqual(want.Free, got.Free) || !decimalEqual(want.Locked, got.Locked) {
			return fmt.Errorf("asset %s free/locked mismatch", asset)
		}
	}
	return nil
}

func compareUnchangedRoutes(evidence spotDemoEvidence, baseline, current spotDemoBaseline) error {
	if len(baseline.Futures) != len(current.Futures) {
		return fmt.Errorf("Futures wallet changed: route set mismatch")
	}
	for venueID, before := range baseline.Futures {
		after, ok := current.Futures[venueID]
		if !ok || !bytes.Equal(before, after) {
			return fmt.Errorf("Futures wallet changed for venue %s", venueID)
		}
	}
	allowed := map[string]struct{}{"BTC": {}, "ETH": {}, "USDT": {}}
	for _, trade := range evidence.Trades {
		allowed[strings.ToUpper(strings.TrimSpace(trade.CommissionAsset))] = struct{}{}
	}
	beforeUndeclared := make(map[string]spotBalanceFact)
	afterUndeclared := make(map[string]spotBalanceFact)
	for asset, balance := range baseline.SpotAssets {
		if _, declared := allowed[asset]; !declared {
			beforeUndeclared[asset] = balance
		}
	}
	for asset, balance := range current.SpotAssets {
		if _, declared := allowed[asset]; !declared {
			afterUndeclared[asset] = balance
		}
	}
	if err := compareBalanceFacts(beforeUndeclared, afterUndeclared); err != nil {
		return fmt.Errorf("undeclared Spot asset changed: %w", err)
	}
	return nil
}

func validateSpotStopResponse(action string, resp *strategyv1.StopStrategyResponse) error {
	if resp == nil || !resp.GetStopped() {
		return fmt.Errorf("stop response did not confirm stopped=true")
	}
	if action == "stop-only" {
		if len(resp.GetTargetResults()) != 0 || resp.GetReconciliationRunId() != "" {
			return fmt.Errorf("stop-only unexpectedly closed targets")
		}
		return nil
	}
	if action != "stop-close" || strings.TrimSpace(resp.GetOperationId()) == "" || strings.TrimSpace(resp.GetReconciliationRunId()) == "" {
		return fmt.Errorf("stop-close response is missing operation or reconciliation identity")
	}
	symbols := make(map[string]struct{})
	for _, result := range resp.GetTargetResults() {
		if result == nil || result.GetExchange() != 1 || result.GetMarket() != 1 {
			return fmt.Errorf("stop-close target escaped Binance Spot")
		}
		statusValue := strings.ToUpper(strings.TrimSpace(result.GetStatus()))
		code := strings.ToUpper(strings.TrimSpace(result.GetCode()))
		if statusValue == "" || strings.Contains(statusValue, "FAIL") || strings.Contains(statusValue, "REJECT") || strings.Contains(code, "FAIL") || strings.Contains(code, "REJECT") {
			return fmt.Errorf("stop-close target failed")
		}
		symbols[strings.ToUpper(strings.TrimSpace(result.GetSymbol()))] = struct{}{}
	}
	if !sameStringSet(symbols, map[string]struct{}{"BTCUSDT": {}, "ETHUSDT": {}}) {
		return fmt.Errorf("stop-close did not report both declared Spot targets")
	}
	return nil
}

type coverageStageConfig struct {
	OutputRoot  string
	RuntimeRoot string
	ReportRoot  string
	RuntimeID   string
}

type coverageStageResult struct {
	PythonInputDir   string
	ValidationLog    string
	PythonShardNames []string
}

type coverageDebugRunner func(context.Context, string, io.Writer) error

type coverageShard struct {
	path string
	info fs.FileInfo
}

func stageRuntimeCoverage(
	ctx context.Context,
	cfg coverageStageConfig,
	validate coverageDebugRunner,
) (coverageStageResult, error) {
	var result coverageStageResult
	if validate == nil {
		return result, fmt.Errorf("locked coverage validator is required")
	}
	outputRoot, err := exactAbsolutePath(cfg.OutputRoot, "output root")
	if err != nil {
		return result, err
	}
	runtimeRoot, err := exactAbsolutePath(cfg.RuntimeRoot, "runtime root")
	if err != nil {
		return result, err
	}
	reportRoot, err := exactAbsolutePath(cfg.ReportRoot, "report root")
	if err != nil {
		return result, err
	}
	runtimeID := strings.TrimSpace(cfg.RuntimeID)
	if runtimeID == "" || strings.ContainsAny(runtimeID, `/\\`) || runtimeID == "." || runtimeID == ".." {
		return result, fmt.Errorf("runtime_id is not a safe path component")
	}
	if runtimeRoot != filepath.Join(outputRoot, "runtimes", runtimeID) {
		return result, fmt.Errorf("runtime root does not match the owned output path")
	}
	if reportRoot != filepath.Join(outputRoot, "smoke-reports", runtimeID) {
		return result, fmt.Errorf("report root does not match the owned host-only path")
	}
	for _, dir := range []string{outputRoot, filepath.Join(outputRoot, "runtimes"), runtimeRoot, filepath.Join(runtimeRoot, "go"), filepath.Join(runtimeRoot, "python")} {
		if err := requireTrustedDirectory(dir); err != nil {
			return result, err
		}
	}

	pythonRoot := filepath.Join(runtimeRoot, "python")
	shards := make([]coverageShard, 0)
	err = filepath.WalkDir(runtimeRoot, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		info, infoErr := os.Lstat(path)
		if infoErr != nil {
			return infoErr
		}
		mode := info.Mode()
		coverageName := strings.HasPrefix(entry.Name(), ".coverage")
		if coverageName && !mode.IsRegular() {
			return fmt.Errorf("coverage shard name is not a regular file: %s", entry.Name())
		}
		if mode&os.ModeSymlink != 0 || (!mode.IsDir() && !mode.IsRegular()) {
			return fmt.Errorf("runtime coverage tree contains a symlink or special file")
		}
		if !coverageName || !mode.IsRegular() {
			return nil
		}
		if filepath.Dir(path) != pythonRoot {
			return fmt.Errorf("coverage shard is outside the Python raw directory")
		}
		shards = append(shards, coverageShard{path: path, info: info})
		return nil
	})
	if err != nil {
		return result, err
	}
	if len(shards) == 0 {
		return result, fmt.Errorf("Python coverage output is missing")
	}
	sort.Slice(shards, func(i, j int) bool {
		return filepath.Base(shards[i].path) < filepath.Base(shards[j].path)
	})

	reportsRoot := filepath.Dir(reportRoot)
	if err := createOrSecureOwnedDirectory(reportsRoot); err != nil {
		return result, err
	}
	if err := createFreshOwnedDirectory(reportRoot); err != nil {
		return result, fmt.Errorf("create fresh report root: %w", err)
	}
	result.PythonInputDir = filepath.Join(reportRoot, "python-input")
	if err := createFreshOwnedDirectory(result.PythonInputDir); err != nil {
		return result, fmt.Errorf("create Python input staging: %w", err)
	}
	result.ValidationLog = filepath.Join(reportRoot, "python-data-validation-output.txt")
	validationLog, err := os.OpenFile(result.ValidationLog, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return result, fmt.Errorf("create Python validation log: %w", err)
	}
	defer validationLog.Close()
	if err := validationLog.Chmod(0o600); err != nil {
		return result, fmt.Errorf("secure Python validation log: %w", err)
	}

	for _, shard := range shards {
		name := filepath.Base(shard.path)
		destination := filepath.Join(result.PythonInputDir, name)
		if err := copyRegularFileIdentityStable(shard.path, shard.info, destination); err != nil {
			return result, err
		}
		result.PythonShardNames = append(result.PythonShardNames, name)
	}
	for _, name := range result.PythonShardNames {
		if _, err := fmt.Fprintf(validationLog, "== %s ==\n", name); err != nil {
			return result, fmt.Errorf("write Python validation log: %w", err)
		}
		staged := filepath.Join(result.PythonInputDir, name)
		if err := validate(ctx, staged, validationLog); err != nil {
			_ = validationLog.Sync()
			return result, fmt.Errorf("validate Python coverage shard %s: %w", name, err)
		}
	}
	if err := validationLog.Sync(); err != nil {
		return result, fmt.Errorf("sync Python validation log: %w", err)
	}
	return result, nil
}

func exactAbsolutePath(value, label string) (string, error) {
	if strings.TrimSpace(value) != value || !filepath.IsAbs(value) || filepath.Clean(value) != value {
		return "", fmt.Errorf("%s must be an absolute cleaned path", label)
	}
	return value, nil
}

func requireTrustedDirectory(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("inspect trusted directory: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return fmt.Errorf("trusted path is not a real directory")
	}
	return nil
}

func createOrSecureOwnedDirectory(path string) error {
	info, err := os.Lstat(path)
	if os.IsNotExist(err) {
		if err := createFreshOwnedDirectory(path); err != nil {
			return fmt.Errorf("create operator report directory: %w", err)
		}
		return nil
	}
	if err != nil {
		return fmt.Errorf("inspect operator report directory: %w", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		return fmt.Errorf("operator report path is not a real directory")
	}
	if err := os.Chmod(path, 0o700); err != nil {
		return fmt.Errorf("secure operator report directory: %w", err)
	}
	return nil
}

func createFreshOwnedDirectory(path string) error {
	if err := os.Mkdir(path, 0o700); err != nil {
		return err
	}
	if err := os.Chmod(path, 0o700); err != nil {
		_ = os.Remove(path)
		return err
	}
	return nil
}

func copyRegularFileIdentityStable(source string, expected fs.FileInfo, destination string) error {
	before, err := os.Lstat(source)
	if err != nil {
		return fmt.Errorf("inspect Python coverage shard before copy: %w", err)
	}
	if !stableFileIdentity(expected, before) {
		return fmt.Errorf("Python coverage shard changed before copy")
	}
	inputFD, err := unix.Open(source, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW, 0)
	if err != nil {
		return fmt.Errorf("open Python coverage shard: %w", err)
	}
	input := os.NewFile(uintptr(inputFD), source)
	if input == nil {
		_ = unix.Close(inputFD)
		return fmt.Errorf("open Python coverage shard: invalid file descriptor")
	}
	defer input.Close()
	opened, err := input.Stat()
	if err != nil {
		return fmt.Errorf("inspect opened Python coverage shard: %w", err)
	}
	if !stableFileIdentity(before, opened) {
		return fmt.Errorf("Python coverage shard was replaced while opening")
	}
	output, err := os.OpenFile(destination, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("create staged Python coverage shard: %w", err)
	}
	removeOutput := true
	defer func() {
		_ = output.Close()
		if removeOutput {
			_ = os.Remove(destination)
		}
	}()
	if err := output.Chmod(0o600); err != nil {
		return fmt.Errorf("secure staged Python coverage shard: %w", err)
	}
	if _, err := io.Copy(output, input); err != nil {
		return fmt.Errorf("copy Python coverage shard: %w", err)
	}
	if err := output.Sync(); err != nil {
		return fmt.Errorf("sync staged Python coverage shard: %w", err)
	}
	if err := output.Close(); err != nil {
		return fmt.Errorf("close staged Python coverage shard: %w", err)
	}
	after, err := os.Lstat(source)
	if err != nil {
		return fmt.Errorf("inspect Python coverage shard after copy: %w", err)
	}
	if !stableFileIdentity(opened, after) {
		return fmt.Errorf("Python coverage shard changed during copy")
	}
	removeOutput = false
	return nil
}

func stableFileIdentity(left, right fs.FileInfo) bool {
	return left != nil && right != nil &&
		left.Mode().IsRegular() && right.Mode().IsRegular() &&
		os.SameFile(left, right) &&
		left.Size() == right.Size() &&
		left.ModTime().Equal(right.ModTime())
}

func lockedCoverageDebugRunner(strategyRoot string) coverageDebugRunner {
	return func(ctx context.Context, shard string, output io.Writer) error {
		cmd := exec.CommandContext(
			ctx,
			"uv", "run", "--frozen", "--extra", "coverage", "coverage", "debug", "data",
		)
		cmd.Dir = strategyRoot
		cmd.Env = environmentWithValue(os.Environ(), "COVERAGE_FILE", shard)
		cmd.Stdout = output
		cmd.Stderr = output
		return cmd.Run()
	}
}

func environmentWithValue(env []string, key, value string) []string {
	prefix := key + "="
	result := make([]string, 0, len(env)+1)
	for _, item := range env {
		if !strings.HasPrefix(item, prefix) {
			result = append(result, item)
		}
	}
	return append(result, prefix+value)
}

func previewReady(resp *strategyv1.PreviewRunStrategyResponse, expectedInputCount int) bool {
	if resp == nil ||
		resp.GetProfile() != "backtest" ||
		!resp.GetSupported() ||
		!resp.GetOk() ||
		len(resp.GetFailures()) != 0 ||
		len(resp.GetDeclaredInputs()) == 0 ||
		expectedInputCount < 0 ||
		(expectedInputCount > 0 && len(resp.GetDeclaredInputs()) != expectedInputCount) {
		return false
	}
	seen := make(map[string]struct{}, len(resp.GetDeclaredInputs()))
	for _, input := range resp.GetDeclaredInputs() {
		if input == nil {
			return false
		}
		parts := []string{
			strings.ToLower(strings.TrimSpace(input.GetExchange())),
			strings.ToLower(strings.TrimSpace(input.GetMarket())),
			strings.ToLower(strings.TrimSpace(input.GetKind())),
			strings.ToUpper(strings.TrimSpace(input.GetSymbol())),
			strings.ToLower(strings.TrimSpace(input.GetInterval())),
		}
		if slices.Contains(parts, "") {
			return false
		}
		key := strings.Join(parts, "\x00")
		if _, duplicate := seen[key]; duplicate {
			return false
		}
		seen[key] = struct{}{}
	}
	return true
}

func waitSessionTerminal(ctx context.Context, addr string, userID int64, sessionID string) string {
	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		fatalRPC("dial portfolio.v1", err)
	}
	defer conn.Close()
	client := portfoliov1.NewPortfolioServiceClient(conn)
	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()
	for {
		resp, err := client.GetSession(ctx, &portfoliov1.GetSessionRequest{SessionId: sessionID, UserId: userID})
		if err != nil {
			fatalRPC("GetSession after StopStrategy", err)
		}
		value := strings.ToLower(strings.TrimSpace(resp.GetSession().GetStatus()))
		if terminalSessionStatus(value) {
			return value
		}
		if knownTerminalSessionStatus(value) {
			fatalf("session reached an unexpected terminal status after StopStrategy: status=%s", value)
		}
		select {
		case <-ctx.Done():
			fatalf("session did not become terminal after StopStrategy")
		case <-ticker.C:
		}
	}
}

func stopRunningSessions(
	ctx context.Context,
	portfolioAddr string,
	userID int64,
	runtimeID string,
	controlClient controlpanelv1.ControlPanelServiceClient,
) int {
	conn, err := grpc.NewClient(portfolioAddr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		fatalRPC("dial portfolio.v1", err)
	}
	defer conn.Close()
	portfolioClient := portfoliov1.NewPortfolioServiceClient(conn)
	stopped := make(map[string]struct{})
	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()

	for {
		response, err := portfolioClient.ListRunningSessions(ctx, &portfoliov1.ListRunningSessionsRequest{
			RuntimeId: runtimeID,
		})
		if err != nil {
			fatalRPC("ListRunningSessions", err)
		}
		ids := runningSessionIDs(response.GetSessions())
		if len(ids) == 0 {
			return len(stopped)
		}
		for _, id := range ids {
			response, err := controlClient.StopStrategy(ctx, &strategyv1.StopStrategyRequest{
				SessionId:  id,
				StopAction: strategyv1.StopAction_STOP_ACTION_STOP_ONLY,
				UserId:     userID,
				RuntimeId:  runtimeID,
			})
			if err == nil && response.GetStopped() {
				stopped[id] = struct{}{}
			}
		}
		select {
		case <-ctx.Done():
			fatalf("runtime sessions did not become terminal")
		case <-ticker.C:
		}
	}
}

func runningSessionIDs(sessions []*portfoliov1.StrategySessionEntry) []string {
	unique := make(map[string]struct{}, len(sessions))
	for _, session := range sessions {
		if session == nil {
			continue
		}
		id := strings.TrimSpace(session.GetSessionId())
		if id != "" {
			unique[id] = struct{}{}
		}
	}
	ids := make([]string, 0, len(unique))
	for id := range unique {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

func terminalSessionStatus(value string) bool {
	return value == "stopped"
}

func knownTerminalSessionStatus(value string) bool {
	switch value {
	case "completed", "finished", "failed", "stopped", "stop_failed", "recoverable", "preflight_failed":
		return true
	default:
		return false
	}
}

func terminalRuntimeStatus(value string) bool {
	return strings.TrimSpace(value) == "cancelled"
}

func selectPortfolio(ctx context.Context, addr string, userID, requestedID int64) int64 {
	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		fatalRPC("dial portfolio.v1", err)
	}
	defer conn.Close()
	client := portfoliov1.NewPortfolioServiceClient(conn)

	if requestedID > 0 {
		portfolio, err := client.GetPortfolio(ctx, &portfoliov1.GetPortfolioRequest{
			PortfolioId: requestedID,
			UserId:      userID,
		})
		if err != nil {
			fatalRPC("GetPortfolio", err)
		}
		if portfolio.GetPortfolio() == nil {
			fatalf("portfolio %d was not returned for user %d", requestedID, userID)
		}
		if !hasActiveStrategy(ctx, client, requestedID) {
			fatalf("portfolio %d has no active strategy", requestedID)
		}
		return requestedID
	}

	list, err := client.ListPortfolios(ctx, &portfoliov1.ListPortfoliosRequest{
		Limit:  100,
		UserId: userID,
	})
	if err != nil {
		fatalRPC("ListPortfolios", err)
	}
	for _, portfolio := range list.GetPortfolios() {
		if portfolio.GetUserId() != userID {
			continue
		}
		if hasActiveStrategy(ctx, client, portfolio.GetPortfolioId()) {
			return portfolio.GetPortfolioId()
		}
	}
	fatalf("user %d has no portfolio with an active strategy", userID)
	return 0
}

func hasActiveStrategy(ctx context.Context, client portfoliov1.PortfolioServiceClient, portfolioID int64) bool {
	active, err := client.GetActiveStrategy(ctx, &portfoliov1.GetActiveStrategyRequest{PortfolioId: portfolioID})
	if err != nil {
		return false
	}
	return active.GetStrategyId() > 0 && strings.TrimSpace(active.GetCode()) != ""
}

func fatalRPC(operation string, err error) {
	if grpcStatus, ok := status.FromError(err); ok {
		fatalf("%s failed: code=%s", operation, grpcStatus.Code())
	}
	fatalf("%s failed", operation)
}

func fatalf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
	os.Exit(1)
}
