package lib

// Ports Firstmate .pi/extensions/lib/fm-async-exec.ts.

import (
	"bytes"
	"context"
	"io"
	"os"
	"os/exec"
	"strconv"
	"sync"
	"time"
)

const DefaultMaxBuffer = 1 << 20

type ExecOptions struct {
	Dir      string
	Env      []string
	Input    string
	MaxBytes int
}

type ExecResult struct {
	Status *int
	Stdout string
	Stderr string
}

// RunCommandAsync owns and joins one process. Cancellation kills the whole
// process group so an awaited extension handler cannot leave child work behind.
func RunCommandAsync(ctx context.Context, command string, args []string, options ExecOptions) ExecResult {
	limit := options.MaxBytes
	if limit <= 0 {
		limit = DefaultMaxBuffer
	}
	cmd := exec.CommandContext(ctx, command, args...)
	cmd.Dir = options.Dir
	if options.Env != nil {
		cmd.Env = options.Env
	}
	cmd.Cancel = func() error {
		if cmd.Process == nil {
			return os.ErrProcessDone
		}
		return cmd.Process.Kill()
	}
	cmd.Stdin = bytes.NewBufferString(options.Input)
	stdout := &boundedBuffer{limit: limit, onLimit: func() { terminateProcess(cmd) }}
	stderr := &boundedBuffer{limit: limit, onLimit: func() { terminateProcess(cmd) }}
	cmd.Stdout, cmd.Stderr = stdout, stderr
	err := cmd.Run()
	result := ExecResult{Stdout: stdout.String(), Stderr: stderr.String()}
	overflow := stdout.exceeded() || stderr.exceeded()
	if stdout.exceeded() {
		result.Stderr += "stdout exceeded " + strconv.Itoa(limit) + " bytes"
	}
	if stderr.exceeded() {
		result.Stderr += "stderr exceeded " + strconv.Itoa(limit) + " bytes"
	}
	if !overflow && cmd.ProcessState != nil && cmd.ProcessState.ExitCode() >= 0 {
		status := cmd.ProcessState.ExitCode()
		result.Status = &status
	}
	if err != nil && result.Status == nil && !overflow {
		result.Stderr += err.Error()
	}
	return result
}

// RunManagedCommand runs an extension-owned long-lived process, forwards its
// stdout and stderr chunks while it runs, and reaps its process group before
// returning. The callback may be invoked concurrently for the two streams.
// Cancellation sends TERM first, then KILL after the bounded grace period.
func RunManagedCommand(ctx context.Context, command string, args []string, options ExecOptions, onOutput func(stream string, chunk []byte)) ExecResult {
	cmd := exec.Command(command, args...)
	cmd.Dir = options.Dir
	if options.Env != nil {
		cmd.Env = options.Env
	}
	configureProcessGroup(cmd)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return ExecResult{Stderr: err.Error()}
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return ExecResult{Stderr: err.Error()}
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return ExecResult{Stderr: err.Error()}
	}
	if err := cmd.Start(); err != nil {
		return ExecResult{Stderr: err.Error()}
	}
	if options.Input != "" {
		_, _ = io.WriteString(stdin, options.Input)
	}
	_ = stdin.Close()

	var readers sync.WaitGroup
	read := func(stream string, source io.Reader) {
		defer readers.Done()
		buffer := make([]byte, 4096)
		for {
			count, readErr := source.Read(buffer)
			if count > 0 && onOutput != nil {
				chunk := append([]byte(nil), buffer[:count]...)
				onOutput(stream, chunk)
			}
			if readErr != nil {
				return
			}
		}
	}
	readers.Add(2)
	go read("stdout", stdout)
	go read("stderr", stderr)
	finished := make(chan error, 1)
	go func() {
		err := cmd.Wait()
		readers.Wait()
		finished <- err
	}()

	var waitErr error
	select {
	case waitErr = <-finished:
	case <-ctx.Done():
		terminateProcessGroupGracefully(cmd)
		timer := time.NewTimer(time.Second)
		select {
		case waitErr = <-finished:
			if !timer.Stop() {
				<-timer.C
			}
		case <-timer.C:
			terminateProcessGroup(cmd)
			waitErr = <-finished
		}
	}
	result := ExecResult{}
	if cmd.ProcessState != nil && cmd.ProcessState.ExitCode() >= 0 {
		status := cmd.ProcessState.ExitCode()
		result.Status = &status
	} else if waitErr != nil && ctx.Err() == nil {
		result.Stderr = waitErr.Error()
	}
	return result
}

type boundedBuffer struct {
	mu      sync.Mutex
	buf     bytes.Buffer
	limit   int
	err     bool
	onLimit func()
}

func (b *boundedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.buf.Len()+len(p) > b.limit {
		b.err = true
		if b.onLimit != nil {
			b.onLimit()
		}
		return 0, errOutputLimit
	}
	return b.buf.Write(p)
}

func (b *boundedBuffer) exceeded() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.err
}

func (b *boundedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func CopyAndCount(dst io.Writer, src io.Reader) (int64, error) { return io.Copy(dst, src) }
