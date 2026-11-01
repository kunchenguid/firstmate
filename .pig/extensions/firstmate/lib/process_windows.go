//go:build windows

package lib

import (
	"errors"
	"os/exec"
)

var errOutputLimit = errors.New("child output exceeded configured byte limit")

func configureProcessGroup(cmd *exec.Cmd) {}
func sessionStartCommand(runner string, args []string) *exec.Cmd {
	return exec.Command(runner, args...)
}
func terminateProcess(cmd *exec.Cmd) {
	if cmd.Process != nil {
		_ = cmd.Process.Kill()
	}
}
func terminateProcessGroup(cmd *exec.Cmd) {
	if cmd.Process != nil {
		_ = cmd.Process.Kill()
	}
}
func terminateProcessGroupGracefully(cmd *exec.Cmd) { terminateProcessGroup(cmd) }
