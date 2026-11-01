package firstmate

// PiG v0.4.1 supports Calm's persisted toggle and working-row widget. Its SDK
// does not expose host transcript presentation, so host-owned rows remain visible.

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/MichaelKinsy/PiG/extensions/sdk"
	"github.com/MichaelKinsy/firstmate-pig-extension/lib"
)

type calmState struct {
	mu      sync.Mutex
	active  bool
	ship    *lib.CalmWorkingShip
	cancel  chan struct{}
	stopped chan struct{}
}

func registerCalm(ext *sdk.Extension, root string) {
	state := &calmState{ship: lib.NewCalmWorkingShip()}
	configDir := os.Getenv("FM_CONFIG_OVERRIDE")
	if configDir == "" {
		configDir = filepath.Join(root, "config")
	}
	preference := filepath.Join(configDir, "calm")

	ext.OnEvent("session_start", func(ctx sdk.Context, _ map[string]any) (any, error) {
		state.setActive(readCalmPreference(preference))
		state.ship.Reset()
		state.applyIdle(ctx)
		return nil, nil
	})
	ext.OnEvent("agent_start", func(ctx sdk.Context, _ map[string]any) (any, error) {
		if state.isActive() {
			state.startShip(ctx)
		}
		return nil, nil
	})
	ext.OnEvent("agent_settled", func(ctx sdk.Context, _ map[string]any) (any, error) {
		state.stopShip()
		state.applyIdle(ctx)
		return nil, nil
	})
	ext.OnEvent("session_shutdown", func(ctx sdk.Context, _ map[string]any) (any, error) {
		state.stopShip()
		state.applyIdle(ctx)
		return nil, nil
	})
	ext.Command("calm", "Toggle Firstmate's working-row presentation. PiG v0.4.1 leaves host transcript rows unchanged.", func(ctx sdk.Context, _ string) error {
		active := !state.isActive()
		if err := writeCalmPreference(preference, active); err != nil {
			return err
		}
		state.setActive(active)
		state.applyIdle(ctx)
		return nil
	})
}

func (s *calmState) setActive(active bool) {
	s.mu.Lock()
	s.active = active
	s.mu.Unlock()
}

func (s *calmState) isActive() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.active
}

// applyIdle settles the working row between runs: the stock indicator is
// visible and the ship widget is gone.
func (s *calmState) applyIdle(ctx sdk.Context) {
	if !ctx.HasUI() {
		return
	}
	ctx.SetWorkingVisible(true)
	_ = ctx.SetWidget(lib.CalmWorkingShipWidgetKey, []string(nil))
}

func (s *calmState) startShip(ctx sdk.Context) {
	if !ctx.HasUI() {
		return
	}
	s.mu.Lock()
	if !s.active || s.cancel != nil {
		s.mu.Unlock()
		return
	}
	cancel := make(chan struct{})
	stopped := make(chan struct{})
	s.cancel, s.stopped = cancel, stopped
	s.mu.Unlock()

	ctx.SetWorkingVisible(false)
	go func() {
		defer close(stopped)
		ticker := time.NewTicker(time.Duration(lib.CalmWorkingShipTickMS) * time.Millisecond)
		defer ticker.Stop()
		render := func() {
			s.ship.ClampToWidth(ctx.Width())
			s.ship.Tick()
			_ = ctx.SetWidget(lib.CalmWorkingShipWidgetKey, s.ship.Render(ctx.Width()))
		}
		render()
		for {
			select {
			case <-cancel:
				return
			case <-ctx.Done():
				return
			case <-ticker.C:
				render()
			}
		}
	}()
}

func (s *calmState) stopShip() {
	s.mu.Lock()
	cancel, stopped := s.cancel, s.stopped
	s.cancel, s.stopped = nil, nil
	s.mu.Unlock()
	if cancel == nil {
		return
	}
	close(cancel)
	<-stopped
}

func readCalmPreference(path string) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	value := strings.TrimSpace(string(data))
	return value == "on" || value == "max"
}

func writeCalmPreference(path string, active bool) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("create Calm preference directory: %w", err)
	}
	value := "off\n"
	if active {
		value = "on\n"
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".calm-*.tmp")
	if err != nil {
		return fmt.Errorf("create Calm preference: %w", err)
	}
	temp := file.Name()
	defer os.Remove(temp)
	if err := file.Chmod(0o600); err != nil {
		_ = file.Close()
		return fmt.Errorf("set Calm preference permissions: %w", err)
	}
	if _, err := file.WriteString(value); err != nil {
		_ = file.Close()
		return fmt.Errorf("write Calm preference: %w", err)
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return fmt.Errorf("sync Calm preference: %w", err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close Calm preference: %w", err)
	}
	if err := os.Rename(temp, path); err != nil {
		return fmt.Errorf("publish Calm preference: %w", err)
	}
	return nil
}
