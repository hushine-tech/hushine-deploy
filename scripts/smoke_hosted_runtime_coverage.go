package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	controlpanelv1 "github.com/hushine-tech/control-panel-service/gen/controlpanelv1"
	portfoliov1 "github.com/hushine-tech/core-service/gen/portfoliov1"
	strategyv1 "github.com/hushine-tech/strategy-service/gen/strategyv1"
	"golang.org/x/sys/unix"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
)

func main() {
	action := flag.String("action", "", "preview, run, expect-end-blocked, stop, stop-running, end, or stage-coverage")
	controlPanelAddr := flag.String("control-panel-addr", "127.0.0.1:50054", "control-panel gRPC address")
	portfolioAddr := flag.String("portfolio-addr", "127.0.0.1:50051", "portfolio.v1 gRPC address")
	userID := flag.Int64("user", 0, "runtime owner user ID")
	runtimeID := flag.String("runtime", "", "runtime ID")
	outputRoot := flag.String("output-root", "", "trusted hosted coverage output root")
	runtimeRoot := flag.String("runtime-root", "", "stopped container's runtime coverage mount")
	reportRoot := flag.String("report-root", "", "operator-owned host-only report root")
	strategyRoot := flag.String("strategy-root", "", "strategy-service source root for locked coverage validation")
	portfolioID := flag.Int64("portfolio", 0, "portfolio ID; zero selects the first owned portfolio with an active strategy")
	sessionID := flag.String("session", "", "strategy session ID")
	startTimeMs := flag.Int64("start-time-ms", 1780272000000, "backtest start time")
	endTimeMs := flag.Int64("end-time-ms", 1783728000000, "backtest end time")
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
		if !previewReady(resp) {
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
		fatalf("-action must be preview, run, expect-end-blocked, stop, stop-running, end, or stage-coverage")
	}
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

func previewReady(resp *strategyv1.PreviewRunStrategyResponse) bool {
	return resp != nil &&
		resp.GetProfile() == "backtest" &&
		resp.GetSupported() &&
		resp.GetOk() &&
		len(resp.GetFailures()) == 0 &&
		len(resp.GetDeclaredInputs()) == 1
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
