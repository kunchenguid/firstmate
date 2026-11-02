package firstmate

import (
	"os"
	"path/filepath"
	"testing"
)

func TestFirstmateRootFallsBackToExtensionLocation(t *testing.T) {
	t.Setenv("FM_ROOT_OVERRIDE", "")
	t.Setenv("FM_HOME", "")
	root := firstmateRoot()
	if !filepath.IsAbs(root) {
		t.Fatalf("root is not absolute: %q", root)
	}
	if _, err := os.Stat(filepath.Join(root, "bin", "fm-session-start.sh")); err != nil {
		t.Fatalf("root %q does not contain Firstmate scripts: %v", root, err)
	}
}
