package lib

// Ports Firstmate .pi/extensions/lib/fm-calm-working-ship.ts and its linked
// sprite implementation at .pi/extensions/lib/fm-calm-working-ship-sprite.ts.

import (
	"fmt"
	"math"
	"strings"
	"sync"
)

const (
	CalmWorkingShipWidgetKey = "firstmate-calm-working-ship"
	CalmWorkingShipTickMS    = 220
	CalmWorkingShipTicksMove = 4
	shipHull                 = "╲▁▁▁╱"
	shipSail                 = "◿│◣"
	shipSailOffset           = 1
	shipHullWidth            = 5
	shipSailWidth            = 3
	waveTroughRadius         = 5
)

type shipColor uint8

const (
	shipPlain shipColor = iota
	shipWater
	shipBoat
)

type shipRun struct {
	text  string
	color shipColor
}

type CalmWorkingShip struct {
	mu        sync.Mutex
	position  int
	direction int
	span      int
	phase     int
	ticks     int
	rendered  shipState
}

type shipState struct{ position, direction, span, phase, ticks int }

func NewCalmWorkingShip() *CalmWorkingShip {
	s := &CalmWorkingShip{position: 0, direction: 1}
	s.commit()
	return s
}

func (s *CalmWorkingShip) Position() int   { s.mu.Lock(); defer s.mu.Unlock(); return s.position }
func (s *CalmWorkingShip) Direction() int  { s.mu.Lock(); defer s.mu.Unlock(); return s.direction }
func (s *CalmWorkingShip) WaterPhase() int { s.mu.Lock(); defer s.mu.Unlock(); return s.phase }

func (s *CalmWorkingShip) Reset() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.position, s.direction, s.span, s.phase, s.ticks = 0, 1, 0, 0, 0
	s.commit()
}

func (s *CalmWorkingShip) ClampToWidth(width int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.applyWidth(width)
}

func (s *CalmWorkingShip) Tick() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ticks++
	s.phase = (s.phase + 1) % CalmWorkingShipTicksMove
	if s.ticks%CalmWorkingShipTicksMove != 0 {
		return
	}
	if s.span <= 0 {
		s.position = 0
		return
	}
	s.position = min(s.span, max(0, s.position+s.direction))
	s.settleDirectionAtEdges()
}

func (s *CalmWorkingShip) RestoreLastRendered() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.position, s.direction, s.span, s.phase, s.ticks = s.rendered.position, s.rendered.direction, s.rendered.span, s.rendered.phase, s.rendered.ticks
}

func (s *CalmWorkingShip) Render(width int) []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	frame := s.frame(width)
	rows := make([]string, len(frame))
	for i, runs := range frame {
		var row strings.Builder
		for _, run := range runs {
			switch run.color {
			case shipWater:
				row.WriteString("\x1b[34m")
				row.WriteString(run.text)
				row.WriteString("\x1b[39m")
			case shipBoat:
				row.WriteString("\x1b[33m")
				row.WriteString(run.text)
				row.WriteString("\x1b[39m")
			default:
				row.WriteString(run.text)
			}
		}
		rows[i] = row.String()
	}
	return rows
}

func (s *CalmWorkingShip) frame(width int) [][]shipRun {
	if width <= 0 {
		return nil
	}
	s.applyWidth(width)
	hullCenter := s.position + (shipSailWidth / 2)
	if width >= shipHullWidth {
		hullCenter = s.position + shipHullWidth/2
	}
	var frame [][]shipRun
	switch {
	case width < shipSailWidth:
		frame = [][]shipRun{s.water(0, width, hullCenter)}
	case width < shipHullWidth:
		row := s.water(0, s.position, hullCenter)
		row = append(row, shipRun{shipSail, shipBoat})
		row = append(row, s.water(s.position+shipSailWidth, width-s.position-shipSailWidth, hullCenter)...)
		frame = [][]shipRun{row}
	default:
		frame = [][]shipRun{
			{{strings.Repeat(" ", s.position+shipSailOffset), shipPlain}, {shipSail, shipBoat}},
		}
		row := s.water(0, s.position, hullCenter)
		row = append(row, shipRun{shipHull, shipBoat})
		row = append(row, s.water(s.position+shipHullWidth, width-s.position-shipHullWidth, hullCenter)...)
		frame = append(frame, row)
	}
	s.commit()
	return frame
}

func (s *CalmWorkingShip) water(from, count, hullCenter int) []shipRun {
	if count <= 0 {
		return nil
	}
	bars := [...]string{"▁", "▂", "▃", "▄"}
	runs := make([]shipRun, count)
	for i := range count {
		level := waveLevel(from+i, hullCenter, s.direction, s.phase)
		runs[i] = shipRun{bars[level], shipWater}
	}
	return runs
}

func (s *CalmWorkingShip) applyWidth(width int) {
	if width <= 0 {
		s.span, s.position = 0, 0
		return
	}
	if width >= shipHullWidth {
		s.span = width - shipHullWidth
	} else if width >= shipSailWidth {
		s.span = width - shipSailWidth
	} else {
		s.span = 0
	}
	s.position = min(s.position, s.span)
	s.settleDirectionAtEdges()
}

func (s *CalmWorkingShip) settleDirectionAtEdges() {
	if s.span <= 0 {
		return
	}
	if s.position >= s.span {
		s.direction = -1
	} else if s.position <= 0 {
		s.direction = 1
	}
}

func (s *CalmWorkingShip) commit() {
	s.rendered = shipState{s.position, s.direction, s.span, s.phase, s.ticks}
}

func waveLevel(column, hullCenter, direction, phase int) int {
	displacement := float64(hullCenter) + float64(direction*phase)/CalmWorkingShipTicksMove
	coordinate := float64(column) - displacement
	if math.Abs(coordinate) <= waveTroughRadius {
		return 0
	}
	beyond := coordinate - math.Copysign(waveTroughRadius, coordinate)
	return max(0, min(3, int(math.Round(waveAmplitude(beyond)))))
}

func waveAmplitude(coordinate float64) float64 {
	negative := coordinate < 0
	distance, rising := math.Abs(coordinate), true
	for index := uint32(0); ; index++ {
		length := float64(halfWaveLength(index, negative))
		if distance <= length {
			eased := smoothstep(distance / length)
			if rising {
				return eased * 3
			}
			return (1 - eased) * 3
		}
		distance -= length
		rising = !rising
	}
}

func halfWaveLength(index uint32, negative bool) uint32 {
	seed := uint32(0x5ea1)
	if negative {
		seed = 0xc411
	}
	value := seed + (index+1)*uint32(0x9e3779b1)
	value ^= value >> 16
	value *= 0x7feb352d
	value ^= value >> 15
	return 9 + value%5
}

func smoothstep(value float64) float64 {
	bounded := max(0, min(1, value))
	return bounded * bounded * (3 - 2*bounded)
}

func (s *CalmWorkingShip) String(width int) string { return fmt.Sprint(s.Render(width)) }
