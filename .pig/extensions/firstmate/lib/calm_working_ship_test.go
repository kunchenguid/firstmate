package lib

import (
	"reflect"
	"strings"
	"testing"
)

func TestCalmShipNarrowAndNormalFrames(t *testing.T) {
	ship := NewCalmWorkingShip()
	if got := ship.Render(0); len(got) != 0 {
		t.Fatalf("zero-width frame = %#v", got)
	}
	if got, want := ship.Render(2), []string{"\x1b[34m▁\x1b[39m\x1b[34m▁\x1b[39m"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("two-cell frame = %#v, want %#v", got, want)
	}
	if got, want := ship.Render(3), []string{"\x1b[33m◿│◣\x1b[39m"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("sail-only frame = %#v, want %#v", got, want)
	}
	if got, want := ship.Render(5), []string{" \x1b[33m◿│◣\x1b[39m", "\x1b[33m╲▁▁▁╱\x1b[39m"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("normal frame = %#v, want %#v", got, want)
	}
}

func TestCalmShipCadenceBounceAndRenderedStateRestore(t *testing.T) {
	ship := NewCalmWorkingShip()
	ship.Render(9) // span = 4
	for range CalmWorkingShipTicksMove - 1 {
		ship.Tick()
	}
	if ship.Position() != 0 || ship.WaterPhase() != 3 {
		t.Fatalf("before boat cadence: position=%d phase=%d", ship.Position(), ship.WaterPhase())
	}
	ship.Tick()
	if ship.Position() != 1 || ship.WaterPhase() != 0 {
		t.Fatalf("after boat cadence: position=%d phase=%d", ship.Position(), ship.WaterPhase())
	}
	ship.Render(9)
	for range 20 {
		ship.Tick()
	}
	ship.RestoreLastRendered()
	if ship.Position() != 1 || ship.WaterPhase() != 0 {
		t.Fatalf("restored state: position=%d phase=%d", ship.Position(), ship.WaterPhase())
	}
	ship.Reset()
	if ship.Position() != 0 || ship.Direction() != 1 || ship.WaterPhase() != 0 {
		t.Fatalf("reset state: position=%d direction=%d phase=%d", ship.Position(), ship.Direction(), ship.WaterPhase())
	}
	ship.Render(9)
	for range 4 * CalmWorkingShipTicksMove {
		ship.Tick()
	}
	if ship.Position() != 4 || ship.Direction() != -1 {
		t.Fatalf("edge bounce state: position=%d direction=%d", ship.Position(), ship.Direction())
	}
}

func TestCalmShipWidthClampNeverOverflowsTheFrame(t *testing.T) {
	ship := NewCalmWorkingShip()
	ship.Render(40)
	for range 20 * CalmWorkingShipTicksMove {
		ship.Tick()
	}
	ship.ClampToWidth(6)
	if got := ship.Position(); got > 1 {
		t.Fatalf("clamped hull position = %d, want at most 1", got)
	}
	rows := ship.Render(6)
	for _, row := range rows {
		plain := strings.ReplaceAll(row, "\x1b[34m", "")
		plain = strings.ReplaceAll(plain, "\x1b[33m", "")
		plain = strings.ReplaceAll(plain, "\x1b[39m", "")
		if len([]rune(plain)) > 6 {
			t.Fatalf("rendered row exceeds six cells: %q", row)
		}
	}
}
