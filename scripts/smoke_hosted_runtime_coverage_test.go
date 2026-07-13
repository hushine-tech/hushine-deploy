package main

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"syscall"
	"testing"

	portfoliov1 "github.com/hushine-tech/core-service/gen/portfoliov1"
	strategyv1 "github.com/hushine-tech/strategy-service/gen/strategyv1"
)

func TestPreviewReadyRequiresExactBacktestContract(t *testing.T) {
	ready := func() *strategyv1.PreviewRunStrategyResponse {
		return &strategyv1.PreviewRunStrategyResponse{
			Profile:        "backtest",
			Supported:      true,
			Ok:             true,
			DeclaredInputs: []*strategyv1.LiveStreamBinding{{}},
		}
	}
	if !previewReady(ready()) {
		t.Fatal("exact backtest preview must be accepted")
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
		{name: "two inputs", mutate: func(resp *strategyv1.PreviewRunStrategyResponse) {
			resp.DeclaredInputs = append(resp.DeclaredInputs, &strategyv1.LiveStreamBinding{})
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			resp := ready()
			tc.mutate(resp)
			if previewReady(resp) {
				t.Fatalf("previewReady accepted %+v", resp)
			}
		})
	}
	if previewReady(nil) {
		t.Fatal("nil preview must be rejected")
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
