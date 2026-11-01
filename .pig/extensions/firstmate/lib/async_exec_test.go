package lib

import (
	"context"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestRunCommandAsyncCapturesOutputAndExitStatus(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fixture uses sh")
	}
	result := RunCommandAsync(context.Background(), "sh", []string{"-c", "printf out; printf err >&2; exit 7"}, ExecOptions{})
	if result.Status == nil || *result.Status != 7 || result.Stdout != "out" || result.Stderr != "err" {
		t.Fatalf("result = %#v", result)
	}
}

func TestRunCommandAsyncOutputLimitReturnsNullStatus(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fixture uses sh")
	}
	result := RunCommandAsync(context.Background(), "sh", []string{"-c", "printf 123456789"}, ExecOptions{MaxBytes: 4})
	if result.Status != nil || len(result.Stdout) > 4 || !strings.Contains(result.Stderr, "stdout exceeded 4 bytes") {
		t.Fatalf("overflow result = %#v", result)
	}
}

func TestRunCommandAsyncCancellationWaitsForChild(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fixture uses sh")
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan ExecResult, 1)
	go func() { done <- RunCommandAsync(ctx, "sh", []string{"-c", "sleep 30"}, ExecOptions{}) }()
	time.Sleep(25 * time.Millisecond)
	cancel()
	select {
	case result := <-done:
		if result.Status != nil {
			t.Fatalf("cancelled command returned status %d", *result.Status)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("command cancellation did not complete")
	}
}

func TestRunManagedCommandStreamsOutputAndJoinsProcessGroupOnCancel(t *testing.T) {
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	chunks := make(chan string, 4)
	done := make(chan ExecResult, 1)
	go func() {
		done <- RunManagedCommand(ctx, "sh", []string{"-c", "trap 'exit 0' TERM; printf 'ready\\n'; while :; do sleep 1; done"}, ExecOptions{}, func(stream string, chunk []byte) {
			chunks <- stream + ":" + string(chunk)
		})
	}()
	select {
	case chunk := <-chunks:
		if chunk != "stdout:ready\n" {
			t.Fatalf("first output chunk = %q, want stdout readiness line", chunk)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("managed child did not report readiness")
	}
	cancel()
	select {
	case result := <-done:
		if result.Status != nil && *result.Status != 0 {
			t.Fatalf("managed child result = %+v, want a clean exit or signal status after TERM", result)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("managed child process group was not joined after cancellation")
	}
}
