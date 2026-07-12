package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"strings"
	"time"

	controlpanelv1 "github.com/hushine-tech/control-panel-service/gen/controlpanelv1"
	portfoliov1 "github.com/hushine-tech/core-service/gen/portfoliov1"
	strategyv1 "github.com/hushine-tech/strategy-service/gen/strategyv1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
)

func main() {
	action := flag.String("action", "", "preview, run, expect-end-blocked, stop, or end")
	controlPanelAddr := flag.String("control-panel-addr", "127.0.0.1:50054", "control-panel gRPC address")
	portfolioAddr := flag.String("portfolio-addr", "127.0.0.1:50051", "portfolio.v1 gRPC address")
	userID := flag.Int64("user", 0, "runtime owner user ID")
	runtimeID := flag.String("runtime", "", "runtime ID")
	portfolioID := flag.Int64("portfolio", 0, "portfolio ID; zero selects the first owned portfolio with an active strategy")
	sessionID := flag.String("session", "", "strategy session ID")
	startTimeMs := flag.Int64("start-time-ms", 1780272000000, "backtest start time")
	endTimeMs := flag.Int64("end-time-ms", 1783728000000, "backtest end time")
	timeout := flag.Duration("timeout", 30*time.Second, "RPC timeout")
	flag.Parse()

	if *userID <= 0 || strings.TrimSpace(*runtimeID) == "" {
		fatalf("required: -user and -runtime")
	}
	ctx, cancel := context.WithTimeout(context.Background(), *timeout)
	defer cancel()

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
		if !resp.GetSupported() || !resp.GetOk() || len(resp.GetFailures()) != 0 || len(resp.GetDeclaredInputs()) == 0 {
			fatalf(
				"PreviewRunStrategy preflight was not ready: profile=%s supported=%t ok=%t failure_count=%d declared_input_count=%d",
				resp.GetProfile(),
				resp.GetSupported(),
				resp.GetOk(),
				len(resp.GetFailures()),
				len(resp.GetDeclaredInputs()),
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
		fatalf("-action must be preview, run, expect-end-blocked, stop, or end")
	}
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
