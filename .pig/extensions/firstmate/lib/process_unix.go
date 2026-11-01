//go:build !windows

package lib

import (
	"errors"
	"os/exec"
	"syscall"
)

var errOutputLimit = errors.New("child output exceeded configured byte limit")

func configureProcessGroup(cmd *exec.Cmd) { cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true} }

func sessionStartCommand(runner string, args []string) *exec.Cmd {
	const supervisor = `parent=$PPID
runner=$$
export FM_SESSIONSTART_SUPERVISOR_PID="$runner"
(
	while kill -0 "$parent" 2>/dev/null && kill -0 "$runner" 2>/dev/null; do sleep 0.05; done
	if ! kill -0 "$parent" 2>/dev/null; then kill -KILL -- "-$runner" 2>/dev/null || :; fi
) >/dev/null 2>&1 &
exec "$@"`
	commandArgs := []string{"-c", supervisor, "fm-sessionstart-supervisor", runner}
	commandArgs = append(commandArgs, args...)
	return exec.Command("bash", commandArgs...)
}

func terminateProcess(cmd *exec.Cmd) {
	if cmd.Process != nil {
		_ = cmd.Process.Kill()
	}
}

func terminateProcessGroup(cmd *exec.Cmd) {
	if cmd.Process == nil {
		return
	}
	_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
}

func terminateProcessGroupGracefully(cmd *exec.Cmd) {
	if cmd.Process != nil {
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGTERM)
	}
}
