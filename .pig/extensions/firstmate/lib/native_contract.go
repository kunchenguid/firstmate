package lib

import "github.com/MichaelKinsy/PiG/extensions/sdk"

// Ports Firstmate .pi/extensions/lib/fm-native-contract.ts. The Pi event bus
// transports function-valued discovery callbacks in-process; this Go form
// makes that host-owned boundary explicit rather than serializing callbacks.

const (
	// NativeToolsEvent is the discovery channel a native-harness adapter emits on.
	NativeToolsEvent             = "firstmate:native-tools"
	SessionStartNudgeMessageType = "firstmate-sessionstart-nudge"
)

type NativeTool struct {
	Name        string
	Description string
	InputSchema map[string]any
	Execute     sdk.ToolFunc
}

type NativeToolDiscovery struct {
	Register         func(NativeTool)
	AllowMessageType func(string)
}

// DiscoverFirstmateTool synchronously offers the exact tool callback and
// declares the only custom message types Firstmate's native host can admit.
// A nil discovery callback represents a host that did not request the tool.
func DiscoverFirstmateTool(discovery NativeToolDiscovery, tool NativeTool) {
	if discovery.Register != nil {
		discovery.Register(tool)
	}
	if discovery.AllowMessageType != nil {
		discovery.AllowMessageType(SessionStartNudgeMessageType)
	}
}
