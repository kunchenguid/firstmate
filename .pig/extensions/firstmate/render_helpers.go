package firstmate

import (
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/MichaelKinsy/PiG/extensions/sdk"
	"github.com/MichaelKinsy/firstmate-pig-extension/lib"
)

var ansiSequence = regexp.MustCompile("\u001b\\[[0-9;:]*[A-Za-z]")

func visibleWidth(text string) int {
	return utf8.RuneCountInString(ansiSequence.ReplaceAllString(text, ""))
}

func wrapRow(row string, width int) []string {
	if width < 1 || visibleWidth(row) <= width {
		return []string{row}
	}
	var rows []string
	var current strings.Builder
	cells := 0
	for i := 0; i < len(row); {
		if loc := ansiSequence.FindStringIndex(row[i:]); loc != nil && loc[0] == 0 {
			current.WriteString(row[i : i+loc[1]])
			i += loc[1]
			continue
		}
		_, size := utf8.DecodeRuneInString(row[i:])
		if cells == width {
			rows = append(rows, current.String())
			current.Reset()
			cells = 0
		}
		current.WriteString(row[i : i+size])
		cells++
		i += size
	}
	return append(rows, current.String())
}

func outcomesShell(theme sdk.UITheme, render sdk.ToolRenderContext, width int, body []string) []string {
	token := "toolSuccessBg"
	if render.IsPartial {
		token = "toolPendingBg"
	} else if render.IsError {
		token = "toolErrorBg"
	}
	inner := max(1, width-2)
	rows := []string{""}
	for _, line := range body {
		for _, logical := range strings.Split(line, "\n") {
			rows = append(rows, wrapRow(logical, inner)...)
		}
	}
	rows = append(rows, "")
	out := make([]string, len(rows))
	for i, row := range rows {
		padded := " " + row
		if pad := width - visibleWidth(padded); pad > 0 {
			padded += strings.Repeat(" ", pad)
		}
		out[i] = theme.Bg(token, padded)
	}
	return out
}

func registerFirstmateTool(ext *sdk.Extension, bus *eventBus, tool sdk.ToolDefinition) {
	ext.RegisterTool(tool)
	bus.On(lib.NativeToolsEvent, func(request any) {
		discovery, ok := request.(lib.NativeToolDiscovery)
		if !ok {
			return
		}
		lib.DiscoverFirstmateTool(discovery, lib.NativeTool{
			Name: tool.Name, Description: tool.Description, InputSchema: tool.Parameters, Execute: tool.Execute,
		})
	})
}
