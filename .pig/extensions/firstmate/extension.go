package firstmate

// Ports Firstmate .pi/extensions/fm-primary-turnend-guard.ts and binds its
// watcher seatbelts and turn-end guard to PiG's Go factory extension host.

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"

	"github.com/MichaelKinsy/PiG/extensions/sdk"
	"github.com/MichaelKinsy/firstmate-pig-extension/lib"
)

const (
	pretoolDeniedExit = 2
	turnEndGuardInput = `{"stop_hook_active":false}`
)

// Extension is the Go factory selected by the Firstmate package. The scripts
// remain Firstmate's guarded operational owners; this factory preserves Pi's
// awaited event ordering and event results around those scripts.
func Extension() *sdk.Extension {
	ext := sdk.New("firstmate")
	root := firstmateRoot()
	if root == "" {
		return ext
	}
	registerTurnEndGuard(ext, root)
	registerSessionStart(ext, root)
	bus := newEventBus()
	registerCalm(ext, root)
	registerWatcher(ext, root, bus)
	return ext
}

func firstmateRoot() string {
	if root := os.Getenv("FM_ROOT_OVERRIDE"); root != "" {
		return root
	}
	return os.Getenv("FM_HOME")
}

func registerTurnEndGuard(ext *sdk.Extension, root string) {
	var guardFollowupActive atomic.Bool
	ext.OnEvent("tool_call", func(ctx sdk.Context, data map[string]any) (any, error) {
		if data["type"] != "tool_call" || data["toolName"] != "bash" {
			return map[string]any{}, nil
		}
		input, _ := data["input"].(map[string]any)
		command, _ := input["command"].(string)
		if command == "" {
			return map[string]any{}, nil
		}
		cdResult := runChecker(ctx, root, "fm-cd-pretool-check.sh", command)
		if cdResult.Code == pretoolDeniedExit {
			return blockedToolCall(cdResult.Stderr, "denied by the cd-guard PreToolUse seatbelt"), nil
		}
		result := runChecker(ctx, root, "fm-arm-pretool-check.sh", command)
		if result.Code != pretoolDeniedExit {
			return map[string]any{}, nil
		}
		return blockedToolCall(result.Stderr, "denied by the watcher-arm PreToolUse seatbelt"), nil
	})

	ext.OnEvent("agent_settled", func(ctx sdk.Context, _ map[string]any) (any, error) {
		if guardFollowupActive.Swap(false) {
			return nil, nil
		}
		result := runGuard(ctx, root)
		if result.Code != pretoolDeniedExit {
			return nil, nil
		}
		guardFollowupActive.Store(true)
		inputCtx, cancel, joined := contextForSDK(ctx.Done())
		defer func() { cancel(); <-joined }()
		content, err := lib.EncodeOperationalInput(inputCtx, lib.KindTurnEndGuard,
			"TURN WOULD END BLIND - supervision is off. The watcher cycle is missing, failed, or unhealthy. Follow the harness recovery instruction below before ending the turn.\n\n"+result.Stderr)
		if err == nil {
			err = ctx.SendUserMessage(content, "followUp")
		}
		if err != nil {
			guardFollowupActive.Store(false)
		}
		return nil, err
	})
}

func blockedToolCall(stderr, fallback string) map[string]any {
	reason := strings.TrimSpace(stderr)
	if reason == "" {
		reason = fallback
	}
	return map[string]any{"block": true, "reason": reason}
}

type checkerResult struct {
	Code   int
	Stderr string
}

func runGuard(ctx sdk.Context, root string) checkerResult {
	args := []string{"-c", "printf '%s' \"$1\" | exec \"$2\"", "fm-turnend-guard", turnEndGuardInput, filepath.Join(root, "bin", "fm-turnend-guard.sh")}
	result := runProcess(ctx, root, "", "bash", args)
	return result
}

func runChecker(ctx sdk.Context, root, script, command string) checkerResult {
	args := []string{"-c", "exec \"$1\" --command \"$2\"", "fm-pretool-check", filepath.Join(root, "bin", script), command}
	return runProcess(ctx, root, "", "bash", args)
}

func runProcess(ctx sdk.Context, root, input, command string, args []string) checkerResult {
	processCtx, cancel, joined := contextForSDK(ctx.Done())
	defer func() { cancel(); <-joined }()
	result := lib.RunCommandAsync(processCtx, command, args, lib.ExecOptions{Dir: root, Input: input})
	// Pi's original runGuard/runChecker helpers treat process creation errors as
	// a non-blocking result. A null signal status likewise is not exit code 2.
	if result.Status == nil {
		return checkerResult{}
	}
	return checkerResult{Code: *result.Status, Stderr: result.Stderr}
}

func contextForSDK(done <-chan struct{}) (context.Context, context.CancelFunc, <-chan struct{}) {
	ctx, cancel := context.WithCancel(context.Background())
	joined := make(chan struct{})
	go func() {
		defer close(joined)
		select {
		case <-done:
			cancel()
		case <-ctx.Done():
		}
	}()
	return ctx, cancel, joined
}
