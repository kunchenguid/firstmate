//go:build windows

package firstmate

import (
	"os"
	"os/exec"
)

func processAlive(process *os.Process) bool {
	return process != nil
}

func detachProcessGroup(*exec.Cmd) {}

func terminateChild(process *os.Process) error {
	return process.Kill()
}

func exitDetails(state *os.ProcessState) (*int, string) {
	if state == nil {
		return nil, ""
	}
	if code := state.ExitCode(); code >= 0 {
		return &code, ""
	}
	return nil, ""
}
