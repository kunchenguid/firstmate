package firstmate

// eventBus is the in-process channel Firstmate's four tracked extensions used
// through Pi's shared pi.events bus. They are one Go extension here, so the bus
// is a plain synchronous dispatcher: Emit returns after every handler ran, and
// handlers run in registration order, as Pi's emitter does.

import (
	"fmt"
	"os"
	"sync"
)

type eventBus struct {
	mu       sync.Mutex
	next     uint64
	channels map[string][]busHandler
}

type busHandler struct {
	id uint64
	fn func(any)
}

func newEventBus() *eventBus { return &eventBus{channels: map[string][]busHandler{}} }

// On registers handler for channel and returns its idempotent unsubscribe.
func (b *eventBus) On(channel string, handler func(any)) func() {
	b.mu.Lock()
	b.next++
	id := b.next
	b.channels[channel] = append(b.channels[channel], busHandler{id: id, fn: handler})
	b.mu.Unlock()
	return func() {
		b.mu.Lock()
		defer b.mu.Unlock()
		handlers := b.channels[channel]
		for i, existing := range handlers {
			if existing.id == id {
				b.channels[channel] = append(append([]busHandler(nil), handlers[:i]...), handlers[i+1:]...)
				return
			}
		}
	}
}

// Emit invokes every handler registered when Emit begins. A panicking handler
// is reported and does not stop later handlers, matching Pi's per-handler
// error containment.
func (b *eventBus) Emit(channel string, data any) {
	b.mu.Lock()
	handlers := append([]busHandler(nil), b.channels[channel]...)
	b.mu.Unlock()
	for _, handler := range handlers {
		func() {
			defer func() {
				if recovered := recover(); recovered != nil {
					fmt.Fprintf(os.Stderr, "Event handler error (%s): %v\n", channel, recovered)
				}
			}()
			handler.fn(data)
		}()
	}
}
