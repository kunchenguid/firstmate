//go:build !windows

package firstmate

import (
	"fmt"
	"os"
	"os/exec"
	"syscall"
)

func processAlive(process *os.Process) bool {
	return process.Signal(syscall.Signal(0)) == nil
}

// detachProcessGroup puts a long-lived arm child in its own process group so
// the host's group kill of a replaced extension process does not take it.
func detachProcessGroup(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

func terminateChild(process *os.Process) error {
	return process.Signal(syscall.SIGTERM)
}

var signalNames = map[syscall.Signal]string{
	syscall.SIGHUP: "SIGHUP", syscall.SIGINT: "SIGINT", syscall.SIGQUIT: "SIGQUIT", syscall.SIGABRT: "SIGABRT",
	syscall.SIGKILL: "SIGKILL", syscall.SIGSEGV: "SIGSEGV", syscall.SIGPIPE: "SIGPIPE", syscall.SIGALRM: "SIGALRM",
	syscall.SIGTERM: "SIGTERM", syscall.SIGUSR1: "SIGUSR1", syscall.SIGUSR2: "SIGUSR2",
}

// exitDetails reports a child's exit code, or the Node-style name of the signal
// that ended it. Exactly one of the two is set.
func exitDetails(state *os.ProcessState) (*int, string) {
	if state == nil {
		return nil, ""
	}
	if status, ok := state.Sys().(syscall.WaitStatus); ok && status.Signaled() {
		if name, known := signalNames[status.Signal()]; known {
			return nil, name
		}
		return nil, fmt.Sprintf("SIG%d", int(status.Signal()))
	}
	if code := state.ExitCode(); code >= 0 {
		return &code, ""
	}
	return nil, ""
}
