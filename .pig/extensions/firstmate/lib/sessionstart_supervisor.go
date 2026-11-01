package lib

// Ports Firstmate .pi/extensions/lib/fm-sessionstart-supervisor.mjs.

import (
	"bytes"
	"context"
	"io"
	"os"
	"strconv"
	"time"
)

type SupervisedResult struct {
	Code      *int
	Bytes     int64
	Stdout    string
	Truncated bool
}

const SessionStartDeliveryBytes = 512 * 1024
const SessionStartTruncatedMarker = "\n\nPI SESSION-START DELIVERY TRUNCATED - the digest exceeded 512 KiB. Treat omitted context as unread and inspect the named files directly before acting on it."

func (r SupervisedResult) DeliveryText() string {
	if !r.Truncated {
		return r.Stdout
	}
	return r.Stdout + SessionStartTruncatedMarker
}

// RunSessionStartCommand runs one owned child process group. It returns only
// after process exit and stdout drain, and cancellation retires the complete
// group before returning to the owning session-start request.
func RunSessionStartCommand(ctx context.Context, runner string, args []string, env []string) SupervisedResult {
	cmd := sessionStartCommand(runner, args)
	if env == nil {
		env = os.Environ()
	}
	cmd.Env = append(append([]string(nil), env...), "FM_SESSIONSTART_SUPERVISOR_PID="+strconv.Itoa(os.Getpid()))
	configureProcessGroup(cmd)
	stdout := &cappedOutput{limit: SessionStartDeliveryBytes}
	cmd.Stdout = stdout
	cmd.Stderr = nil
	if err := cmd.Start(); err != nil {
		return SupervisedResult{}
	}
	finished := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			terminateProcessGroupGracefully(cmd)
			timer := time.NewTimer(time.Second)
			defer timer.Stop()
			select {
			case <-finished:
			case <-timer.C:
				terminateProcessGroup(cmd)
			}
		case <-finished:
		}
	}()
	_ = cmd.Wait()
	close(finished)
	result := SupervisedResult{Bytes: stdout.total, Stdout: stdout.buffer.String(), Truncated: stdout.total > int64(stdout.buffer.Len())}
	if cmd.ProcessState != nil {
		code := cmd.ProcessState.ExitCode()
		if code >= 0 {
			result.Code = &code
		}
	}
	return result
}

type cappedOutput struct {
	buffer bytes.Buffer
	limit  int
	total  int64
}

func (w *cappedOutput) Write(p []byte) (int, error) {
	n := len(p)
	w.total += int64(n)
	remaining := w.limit - w.buffer.Len()
	if remaining > 0 {
		if len(p) > remaining {
			p = p[:remaining]
		}
		_, _ = w.buffer.Write(p)
	}
	return n, nil
}

var _ io.Writer = (*cappedOutput)(nil)
