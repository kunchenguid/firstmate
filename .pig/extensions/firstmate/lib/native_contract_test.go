package lib

import (
	"reflect"
	"testing"

	"github.com/MichaelKinsy/PiG/extensions/sdk"
)

func TestDiscoverFirstmateToolPreservesExecuteAndMessageAllowlist(t *testing.T) {
	called := false
	tool := NativeTool{
		Name: "fm_watch_arm_pi", Description: "arm watcher",
		InputSchema: map[string]any{"type": "object"},
		Execute:     func(_ sdk.Context, _ map[string]any) (any, error) { called = true; return nil, nil },
	}
	var got NativeTool
	var allowed []string
	DiscoverFirstmateTool(NativeToolDiscovery{
		Register:         func(value NativeTool) { got = value },
		AllowMessageType: func(value string) { allowed = append(allowed, value) },
	}, tool)
	if got.Name != tool.Name || got.Description != tool.Description || !reflect.DeepEqual(got.InputSchema, tool.InputSchema) {
		t.Fatalf("registered tool = %#v", got)
	}
	if got.Execute == nil {
		t.Fatal("registered tool lost its execute callback")
	}
	if _, err := got.Execute(sdk.Context{}, nil); err != nil || !called {
		t.Fatalf("execute callback called=%v error=%v", called, err)
	}
	want := []string{SessionStartNudgeMessageType}
	if !reflect.DeepEqual(allowed, want) {
		t.Fatalf("allowed message types = %#v, want %#v", allowed, want)
	}
}
