package firstmate

// Registers the Firstmate watcher bridge (fm-primary-pi-watch.ts) on the Go
// extension: its host events, the /fm-watch-arm-pi command and the
// fm_watch_arm_pi tool.

import (
	"fmt"
	"os"
	"strings"

	"github.com/MichaelKinsy/PiG/extensions/sdk"
)

const watchArmToolDescription = "Start the first required Pi watcher cycle, or repair one only after a notification says the cycle is missing, failed, or unhealthy. Do not call after ordinary work or ordinary notifications; the Pi extension re-arms automatically. Never run bin/fm-watch-arm.sh through bash."

func registerWatcher(ext *sdk.Extension, root string, bus *eventBus) *watcher {
	w := newWatcher(root, bus)
	// Publish this generation while the lock is absent so that session-start can
	// tell a loaded extension from a missing one.
	if err := w.bindInitialMarker(); err != nil {
		fmt.Fprintf(os.Stderr, "Firstmate watcher: could not publish its extension marker: %v\n", err)
	}
	ext.OnEvent("before_agent_start", func(ctx sdk.Context, event map[string]any) (any, error) {
		w.setHost(ctx)
		prompt, _ := event["prompt"].(string)
		return nil, w.onBeforeAgentStart(prompt)
	})
	ext.OnEvent("message_start", func(ctx sdk.Context, event map[string]any) (any, error) {
		w.setHost(ctx)
		message, _ := event["message"].(map[string]any)
		w.onMessageStart(message)
		return nil, nil
	})
	ext.OnEvent("session_start", func(ctx sdk.Context, _ map[string]any) (any, error) {
		w.setHost(ctx)
		return nil, w.onSessionStart()
	})
	ext.OnEvent("session_shutdown", func(ctx sdk.Context, event map[string]any) (any, error) {
		w.setHost(ctx)
		reason, _ := event["reason"].(string)
		return nil, w.onSessionShutdown(reason)
	})
	ext.Command("fm-watch-arm-pi", "Arm firstmate watcher supervision through the Pi extension instead of foreground bash.", func(ctx sdk.Context, _ string) error {
		w.setHost(ctx)
		result, err := w.arm()
		if err != nil {
			return err
		}
		level := "warning"
		if result.OK {
			level = "info"
		}
		ctx.Notify(result.Message, level)
		return nil
	})
	registerFirstmateTool(ext, bus, sdk.ToolDefinition{
		Name:          "fm_watch_arm_pi",
		Label:         "Arm firstmate watcher",
		Description:   watchArmToolDescription,
		PromptSnippet: "Start the first required Pi watcher cycle or repair a cycle reported missing, failed, or unhealthy; ordinary re-arming is automatic.",
		PromptGuidelines: []string{
			"Call fm_watch_arm_pi only for the first required cycle or after a notification says the cycle is missing, failed, or unhealthy. Do not call it after ordinary work, turn completion, or ordinary signal, stale, check, or heartbeat handling because the Pi extension owns re-arming. Never run bin/fm-watch-arm.sh through bash.",
		},
		Parameters:   sdk.Schema{"type": "object", "properties": map[string]any{}},
		RenderShell:  sdk.ToolRenderShellSelf,
		RenderCall:   watchToolCall(),
		RenderResult: watchToolResult(),
		Execute: func(ctx sdk.Context, _ map[string]any) (any, error) {
			w.setHost(ctx)
			result, err := w.arm()
			if err != nil {
				return nil, err
			}
			return sdk.ToolResult{Content: result.Message, Details: result}, nil
		},
	})
	return w
}

const watchResultStateKey = "fmWatchResult"

// watchToolCall draws the arm tool's call row: hidden under Calm, the bare title
// in an export, and otherwise a self-framed card that also holds the result.
func watchToolCall() sdk.ToolRenderCallFunc {
	return func(ctx sdk.Context, _ map[string]any, render sdk.ToolRenderContext, width int) ([]string, error) {
		return watchCallLines(ctx.UITheme(), render, width), nil
	}
}

func watchToolResult() sdk.ToolRenderResultFunc {
	return func(ctx sdk.Context, result sdk.ToolRenderResult, _ sdk.ToolRenderResultOptions, render sdk.ToolRenderContext, _ int) ([]string, error) {
		return watchResultLines(ctx.UITheme(), result, render), nil
	}
}

func watchCallLines(theme sdk.UITheme, render sdk.ToolRenderContext, width int) []string {
	title := theme.Fg("toolTitle", theme.Bold("fm_watch_arm_pi"))
	body := []string{title}
	if result, ok := render.State[watchResultStateKey].([]string); ok {
		body = append(body, result...)
	}
	return outcomesShell(theme, render, width, body)
}

func watchResultLines(theme sdk.UITheme, result sdk.ToolRenderResult, render sdk.ToolRenderContext) []string {
	var texts []string
	for _, item := range result.Content {
		if item["type"] == "text" {
			text, _ := item["text"].(string)
			texts = append(texts, text)
		}
	}
	output := strings.Join(texts, "\n")
	var rendered []string
	if output != "" {
		rendered = []string{theme.Fg("toolOutput", output)}
	}
	previous, _ := render.State[watchResultStateKey].([]string)
	render.State[watchResultStateKey] = rendered
	if strings.Join(previous, "\n") != strings.Join(rendered, "\n") && render.Invalidate != nil {
		render.Invalidate()
	}
	return []string{}
}
