package lib

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestSessionStartSupervisorDrainsOutputAndReportsCode(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fixture uses a POSIX shell script")
	}
	script := filepath.Join(t.TempDir(), "runner")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nprintf 'pid=%s\\n' \"$FM_SESSIONSTART_SUPERVISOR_PID\"\nprintf 'hidden' >&2\nexit 7\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	result := RunSessionStartCommand(context.Background(), script, nil, nil)
	if result.Code == nil || *result.Code != 7 {
		t.Fatalf("runner code = %v, want 7", result.Code)
	}
	if !strings.HasPrefix(result.Stdout, "pid=") || result.Bytes != int64(len(result.Stdout)) {
		t.Fatalf("supervised output = %#v", result)
	}
	if strings.Contains(result.Stdout, "hidden") {
		t.Fatalf("stderr reached captured stdout: %q", result.Stdout)
	}
}

func TestSessionStartSupervisorKillsRunnerWhenOwnerProcessDies(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fixture checks Unix process groups")
	}
	if os.Getenv("FM_SESSIONSTART_OWNER_HELPER") == "1" {
		result := RunSessionStartCommand(context.Background(), os.Getenv("FM_SESSIONSTART_RUNNER"), nil, nil)
		if result.Code != nil {
			os.Exit(0)
		}
		os.Exit(0)
	}
	root := t.TempDir()
	pidPath := filepath.Join(root, "runner.pid")
	runner := filepath.Join(root, "runner.sh")
	if err := os.WriteFile(runner, []byte("#!/bin/sh\nprintf '%s\\n' \"$FM_SESSIONSTART_SUPERVISOR_PID\" > \"$FM_SESSIONSTART_PID_FILE\"\nexec sleep 30\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	helper := exec.Command(os.Args[0], "-test.run=^TestSessionStartSupervisorKillsRunnerWhenOwnerProcessDies$")
	helper.Env = append(os.Environ(), "FM_SESSIONSTART_OWNER_HELPER=1", "FM_SESSIONSTART_RUNNER="+runner, "FM_SESSIONSTART_PID_FILE="+pidPath)
	if err := helper.Start(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	var pid int
	for time.Now().Before(deadline) {
		data, err := os.ReadFile(pidPath)
		if err == nil {
			pid, err = strconv.Atoi(strings.TrimSpace(string(data)))
			if err != nil {
				t.Fatal(err)
			}
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if pid == 0 {
		_ = helper.Process.Kill()
		_ = helper.Wait()
		t.Fatal("supervised runner did not publish its process id")
	}
	if err := helper.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	_ = helper.Wait()
	process, err := os.FindProcess(pid)
	if err != nil {
		t.Fatal(err)
	}
	for time.Now().Before(deadline) {
		if err := process.Signal(syscall.Signal(0)); err != nil {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("session-start process %d survived after its owner exited", pid)
}

func TestSessionStartSupervisorBoundsRetainedStdoutAndCountsAllBytes(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fixture uses POSIX tools")
	}
	result := RunSessionStartCommand(context.Background(), "sh", []string{"-c", "head -c 600000 /dev/zero"}, nil)
	if result.Code == nil || *result.Code != 0 {
		t.Fatalf("status = %v", result.Code)
	}
	if result.Bytes != 600000 || len(result.Stdout) != SessionStartDeliveryBytes || !result.Truncated {
		t.Fatalf("output bytes=%d retained=%d truncated=%v", result.Bytes, len(result.Stdout), result.Truncated)
	}
	if !strings.HasSuffix(result.DeliveryText(), SessionStartTruncatedMarker) {
		t.Fatal("truncated delivery omitted Firstmate's unread-context marker")
	}
}

func TestSessionStartSupervisorCancellationReapsChildGroup(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fixture uses a POSIX shell process group")
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan SupervisedResult, 1)
	go func() { done <- RunSessionStartCommand(ctx, "/bin/sh", []string{"-c", "sleep 30"}, nil) }()
	time.Sleep(40 * time.Millisecond)
	cancel()
	select {
	case got := <-done:
		if got.Code != nil {
			t.Fatalf("cancelled child reported exit code %d", *got.Code)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("cancel did not stop and reap the session-start child group")
	}
}
