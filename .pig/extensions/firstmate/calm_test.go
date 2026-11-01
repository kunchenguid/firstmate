package firstmate

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCalmPreferencePersistsAtomicOnAndOffValues(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config", "calm")
	if readCalmPreference(path) {
		t.Fatal("missing preference must default to Calm off")
	}
	if err := writeCalmPreference(path, true); err != nil {
		t.Fatal(err)
	}
	if !readCalmPreference(path) {
		t.Fatal("on preference did not restore Calm")
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := info.Mode().Perm(); got != 0o600 {
		t.Fatalf("preference permissions = %04o, want 0600", got)
	}
	if err := writeCalmPreference(path, false); err != nil {
		t.Fatal(err)
	}
	if readCalmPreference(path) {
		t.Fatal("off preference restored Calm as active")
	}
	if err := os.WriteFile(path, []byte("max\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if !readCalmPreference(path) {
		t.Fatal("legacy max preference must restore the current Calm presentation")
	}
}
