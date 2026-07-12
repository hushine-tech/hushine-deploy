package main

import (
	"testing"

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
