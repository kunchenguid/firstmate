package firstmate

import (
	"strings"
	"testing"

	"github.com/MichaelKinsy/PiG/extensions/sdk"
)

func stripSGR(text string) string { return ansiSequence.ReplaceAllString(text, "") }

func textResult(text string) sdk.ToolRenderResult {
	return sdk.ToolRenderResult{Content: []map[string]any{{"type": "text", "text": text}}}
}

func TestWatchToolRendererIncorporatesResultAndRendersCard(t *testing.T) {
	theme := sdk.UITheme{}
	state := map[string]any{}
	render := sdk.ToolRenderContext{State: state, Invalidate: func() { state["invalidated"] = true }}
	result := watchResultLines(theme, textResult("armed"), render)
	if len(result) != 0 || state["invalidated"] != true {
		t.Fatalf("result should be incorporated into the call card: %q", result)
	}
	call := watchCallLines(theme, render, 40)
	framed := stripSGR(strings.Join(call, "\n"))
	if !strings.Contains(framed, "fm_watch_arm_pi") || !strings.Contains(framed, "armed") || len(call) != 4 {
		t.Fatalf("framed card = %q", call)
	}
}

func TestWrapRowPreservesANSIAndBoundsVisibleWidth(t *testing.T) {
	rows := wrapRow("\u001b[31mabcdef\u001b[0m", 3)
	if len(rows) != 2 || visibleWidth(rows[0]) != 3 || visibleWidth(rows[1]) != 3 {
		t.Fatalf("wrapped rows = %#v", rows)
	}
}
