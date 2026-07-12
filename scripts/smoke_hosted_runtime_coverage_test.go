package main

import "testing"

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
