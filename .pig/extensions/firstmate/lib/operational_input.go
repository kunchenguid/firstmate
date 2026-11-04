package lib

// Ports Firstmate .pi/extensions/lib/fm-operational-input.ts.

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

type OperationalKind string

const (
	KindSessionStart   OperationalKind = "session-start"
	KindWatcher        OperationalKind = "watcher"
	KindTurnEndGuard   OperationalKind = "turn-end-guard"
	KindAwaySupervisor OperationalKind = "away-supervisor"
	KindFromFirstmate  OperationalKind = "from-firstmate"
	KindLaunchBrief    OperationalKind = "launch-brief"
	KindBranchOutcome  OperationalKind = "branch-outcome"
)

var operationalKinds = []OperationalKind{
	KindSessionStart, KindWatcher, KindTurnEndGuard, KindAwaySupervisor,
	KindFromFirstmate, KindLaunchBrief, KindBranchOutcome,
}

func OperationalKinds() []OperationalKind { return append([]OperationalKind(nil), operationalKinds...) }

func operationalScript() string {
	if script := os.Getenv("FM_OPERATIONAL_INPUT_SCRIPT"); script != "" {
		return script
	}
	root := os.Getenv("FM_ROOT_OVERRIDE")
	if root == "" {
		root = os.Getenv("FM_HOME")
	}
	if root == "" {
		return ""
	}
	return filepath.Join(root, "bin", "fm-operational-input.sh")
}

func invocation(script string, args ...string) (string, []string) {
	if runtime.GOOS == "windows" {
		return "bash", append([]string{script}, args...)
	}
	return script, args
}

func runOperational(ctx context.Context, op string, kind OperationalKind, content string) (string, bool) {
	script := operationalScript()
	if script == "" {
		return "", false
	}
	args := []string{op}
	if op == "encode" {
		args = append(args, string(kind))
	}
	command, args := invocation(script, args...)
	result := RunCommandAsync(ctx, command, args, ExecOptions{Input: content, MaxBytes: DefaultMaxBuffer})
	if result.Status == nil || *result.Status != 0 {
		return "", false
	}
	if op == "classify" {
		return strings.TrimSuffix(result.Stdout, "\n"), true
	}
	return result.Stdout, true
}

func EncodeOperationalInput(ctx context.Context, kind OperationalKind, content string) (string, error) {
	if !knownOperationalKind(kind) {
		return "", errors.New("unknown Firstmate operational input kind")
	}
	encoded, ok := runOperational(ctx, "encode", kind, content)
	if !ok {
		return "", errors.New("could not encode Firstmate operational input kind " + string(kind))
	}
	return encoded, nil
}

func ClassifyOperationalText(ctx context.Context, content string) (string, bool) {
	return runOperational(ctx, "classify", "", content)
}

func ClassifyCurrentOperationalText(ctx context.Context, content string) (OperationalKind, bool) {
	value, ok := runOperational(ctx, "kind", "", content)
	return OperationalKind(value), ok && value != ""
}

func IsOperationalPresentationText(ctx context.Context, content string) bool {
	if !strings.ContainsRune(content, '\u2063') {
		return false
	}
	if _, ok := ClassifyCurrentOperationalText(ctx, content); ok {
		return true
	}
	return strings.HasPrefix(content, "\u2063Supervisor escalate (")
}

func knownOperationalKind(kind OperationalKind) bool {
	for _, candidate := range operationalKinds {
		if candidate == kind {
			return true
		}
	}
	return false
}

var ErrOperationalInputCanceled = context.Canceled
