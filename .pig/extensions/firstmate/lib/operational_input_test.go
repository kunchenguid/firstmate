package lib

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestOperationalInputUsesScriptAndPreservesEncodedOutput(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("fixture uses a POSIX shell script")
	}
	script := filepath.Join(t.TempDir(), "operational-input")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nread kind\nprintf 'kind=%s:%s\\n' \"$2\" \"$kind\"\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("FM_OPERATIONAL_INPUT_SCRIPT", script)
	got, err := EncodeOperationalInput(context.Background(), KindWatcher, "wake\n")
	if err != nil {
		t.Fatal(err)
	}
	if got != "kind=watcher:wake\n" {
		t.Fatalf("encoded value = %q", got)
	}
}

func TestOperationalKindInventoryIsClosedAndCopied(t *testing.T) {
	kinds := OperationalKinds()
	if len(kinds) != 7 || kinds[0] != KindSessionStart || kinds[6] != KindBranchOutcome {
		t.Fatalf("operational kinds = %#v", kinds)
	}
	kinds[0] = "corrupt"
	if OperationalKinds()[0] != KindSessionStart {
		t.Fatal("caller mutated the shared operational-kind inventory")
	}
	if _, err := EncodeOperationalInput(context.Background(), "invented", "x"); err == nil {
		t.Fatal("unknown operational kind was accepted")
	}
}
