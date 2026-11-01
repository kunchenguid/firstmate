package firstmate

// Ports session-start supervision from Firstmate
// .pi/extensions/fm-primary-turnend-guard.ts and its process wrapper at
// .pi/extensions/lib/fm-sessionstart-supervisor.mjs.

import (
	"context"
	"path/filepath"
	"strings"
	"sync"

	"github.com/MichaelKinsy/PiG/extensions/sdk"
	"github.com/MichaelKinsy/firstmate-pig-extension/lib"
)

const (
	sessionStartManualFallback = "Run `bin/fm-session-start.sh` now, exactly once, before executing any other instructions."
	sessionStartIneligibleExit = 3
)

type sessionStartResultKind uint8

const (
	sessionStartReady sessionStartResultKind = iota
	sessionStartEmpty
	sessionStartFailed
	sessionStartIneligible
	sessionStartCancelled
)

type sessionStartResult struct {
	kind sessionStartResultKind
	raw  string
}

type sessionStartGeneration struct {
	id        uint64
	sessionID string
	source    string
	ctx       context.Context
	cancel    context.CancelFunc
	done      chan struct{}
	result    chan sessionStartResult
	delivered bool
}

type sessionStartOwner struct {
	mu     sync.Mutex
	nextID uint64
	active *sessionStartGeneration
}

func registerSessionStart(ext *sdk.Extension, root string) {
	owner := &sessionStartOwner{}
	ext.OnEvent("session_start", func(ctx sdk.Context, event map[string]any) (any, error) {
		source := sessionStartSource(event)
		if source == "" {
			return nil, nil
		}
		sessionID, _ := ctx.SessionManager().GetSessionID()
		owner.replace(source, sessionID, root)
		return nil, nil
	})
	ext.OnEvent("before_agent_start", func(ctx sdk.Context, _ map[string]any) (any, error) {
		generation := owner.current()
		if generation == nil {
			sessionID, _ := ctx.SessionManager().GetSessionID()
			generation = owner.startIfMissing(sessionID, root)
		}
		message, ok := owner.claimGeneration(ctx, root, generation)
		if !ok {
			return nil, nil
		}
		return map[string]any{"message": message}, nil
	})
	ext.OnEvent("session_compact", func(ctx sdk.Context, _ map[string]any) (any, error) {
		sessionID, _ := ctx.SessionManager().GetSessionID()
		generation := owner.replace("compact", sessionID, root)
		message, ok := owner.claimGeneration(ctx, root, generation)
		if !ok || !owner.live(generation) {
			return nil, nil
		}
		err := ctx.SendCustomMessage(sdk.CustomMessage{
			CustomType: lib.SessionStartNudgeMessageType,
			Content:    message["content"],
			Display:    false,
			Details:    map[string]any{"kind": "session-start"},
		}, sdk.SendMessageOptions{})
		if err != nil {
			owner.unclaim(generation)
		}
		return nil, err
	})
	ext.OnEvent("session_shutdown", func(_ sdk.Context, _ map[string]any) (any, error) {
		generation := owner.current()
		if generation == nil {
			return nil, nil
		}
		generation.cancel()
		<-generation.done
		owner.clear(generation)
		return nil, nil
	})
}

func sessionStartSource(event map[string]any) string {
	reason, _ := event["reason"].(string)
	switch reason {
	case "startup":
		// Pi may report startup for --continue/--resume/--session. The Go
		// extension process cannot inspect Pi's argv; use only explicit host
		// provenance if a future host supplies it, otherwise retain startup.
		if source, ok := event["startupSource"].(string); ok && (source == "resume" || source == "fork") {
			return source
		}
		return "startup"
	case "new":
		return "clear"
	case "resume", "fork":
		return reason
	default:
		return ""
	}
}

func (o *sessionStartOwner) startIfMissing(sessionID, root string) *sessionStartGeneration {
	o.mu.Lock()
	if o.active != nil {
		generation := o.active
		o.mu.Unlock()
		return generation
	}
	o.nextID++
	generationCtx, cancel := context.WithCancel(context.Background())
	generation := &sessionStartGeneration{
		id: o.nextID, sessionID: sessionID, source: "startup", ctx: generationCtx, cancel: cancel,
		done: make(chan struct{}), result: make(chan sessionStartResult, 1),
	}
	o.active = generation
	o.mu.Unlock()
	go func() {
		defer close(generation.done)
		generation.result <- runSessionStart(generation.ctx, root, generation.source)
	}()
	return generation
}

func (o *sessionStartOwner) replace(source, sessionID, root string) *sessionStartGeneration {
	o.mu.Lock()
	o.nextID++
	generationCtx, cancel := context.WithCancel(context.Background())
	generation := &sessionStartGeneration{
		id: o.nextID, sessionID: sessionID, source: source, ctx: generationCtx, cancel: cancel,
		done: make(chan struct{}), result: make(chan sessionStartResult, 1),
	}
	previous := o.active
	o.active = generation
	o.mu.Unlock()
	go func() {
		defer close(generation.done)
		if previous != nil {
			previous.cancel()
			<-previous.done
		}
		if !o.live(generation) {
			generation.result <- sessionStartResult{kind: sessionStartCancelled}
			return
		}
		generation.result <- runSessionStart(generation.ctx, root, source)
	}()
	return generation
}

func runSessionStart(ctx context.Context, root, source string) sessionStartResult {
	result := lib.RunSessionStartCommand(ctx, filepath.Join(root, "bin", "fm-sessionstart-run.sh"), []string{"--source", source, "--pi-prerequisite"}, nil)
	if ctx.Err() != nil {
		return sessionStartResult{kind: sessionStartCancelled}
	}
	if result.Code == nil {
		return sessionStartResult{kind: sessionStartFailed}
	}
	if *result.Code == sessionStartIneligibleExit {
		return sessionStartResult{kind: sessionStartIneligible}
	}
	if *result.Code != 0 {
		return sessionStartResult{kind: sessionStartFailed}
	}
	raw := strings.TrimFunc(result.Stdout, func(r rune) bool {
		return r == '\uFEFF' || (r != '\u0085' && (r == ' ' || r == '\t' || r == '\n' || r == '\r' || r == '\v' || r == '\f' || r >= 0x2000 && r <= 0x200a || r == 0x2028 || r == 0x2029 || r == 0x3000))
	})
	if result.Truncated {
		raw += lib.SessionStartTruncatedMarker
	}
	if raw == "" {
		return sessionStartResult{kind: sessionStartEmpty}
	}
	return sessionStartResult{kind: sessionStartReady, raw: raw}
}

func (o *sessionStartOwner) claim(ctx sdk.Context, root string) (map[string]any, bool) {
	return o.claimGeneration(ctx, root, o.current())
}

func (o *sessionStartOwner) claimGeneration(ctx sdk.Context, root string, generation *sessionStartGeneration) (map[string]any, bool) {
	if generation == nil {
		return nil, false
	}
	var result sessionStartResult
	select {
	case result = <-generation.result:
		// Retain one completed result for a retry or a replacement event.
		generation.result <- result
	case <-ctx.Done():
		return nil, false
	}
	currentSessionID, _ := ctx.SessionManager().GetSessionID()
	o.mu.Lock()
	if o.active != generation || generation.delivered {
		o.mu.Unlock()
		return nil, false
	}
	if generation.sessionID != "" && currentSessionID != "" && generation.sessionID != currentSessionID {
		o.mu.Unlock()
		return nil, false
	}
	generation.delivered = true
	o.mu.Unlock()
	raw := ""
	if result.kind == sessionStartReady {
		raw = result.raw
	} else if result.kind == sessionStartFailed || result.kind == sessionStartEmpty && (generation.source == "startup" || generation.source == "clear" || generation.source == "compact") {
		raw = sessionStartManualFallback
	}
	if raw == "" {
		return nil, false
	}
	classifyCtx, cancel, joined := contextForSDK(ctx.Done())
	defer func() { cancel(); <-joined }()
	content := raw
	if _, ok := lib.ClassifyCurrentOperationalText(classifyCtx, raw); !ok {
		encoded, err := lib.EncodeOperationalInput(classifyCtx, lib.KindSessionStart, raw)
		if err != nil {
			return nil, false
		}
		content = encoded
	}
	return map[string]any{"customType": lib.SessionStartNudgeMessageType, "content": content, "display": false, "details": map[string]any{"kind": "session-start"}}, true
}

func (o *sessionStartOwner) current() *sessionStartGeneration {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.active
}

func (o *sessionStartOwner) live(generation *sessionStartGeneration) bool {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.active == generation && generation.ctx.Err() == nil
}

func (o *sessionStartOwner) unclaim(generation *sessionStartGeneration) {
	o.mu.Lock()
	if o.active == generation {
		generation.delivered = false
	}
	o.mu.Unlock()
}

func (o *sessionStartOwner) clear(generation *sessionStartGeneration) {
	o.mu.Lock()
	if o.active == generation {
		o.active = nil
	}
	o.mu.Unlock()
}
