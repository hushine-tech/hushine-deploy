package main

import "testing"

func TestOwnedKafkaTopicValidation(t *testing.T) {
	owner := "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
	valid := "runtime.restart.acceptance." + owner
	if !isOwnedKafkaTopic(valid) {
		t.Fatalf("derived owner topic was rejected: %s", valid)
	}
	for _, topic := range []string{
		"notification.events",
		"runtime.restart.acceptance.short",
		"runtime.restart.acceptance.0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeg",
		"runtime.restart.acceptance.0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef",
	} {
		if isOwnedKafkaTopic(topic) {
			t.Errorf("non-owned topic was accepted: %s", topic)
		}
	}
}
