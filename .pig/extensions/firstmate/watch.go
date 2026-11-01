package firstmate

// Ports Firstmate .pi/extensions/fm-primary-pi-watch.ts.
//
// Session-generation ownership: only the active live generation may start,
// stop, rearm, or clear the arm child. Replacement shutdown publishes a
// generation-bound handoff phase but retains its established child until the
// next owning session_start commits the tracked replacement arm without a model
// turn. Terminal quit leaves the final generation stopped so late callbacks
// cannot rearm. Stale callbacks from a prior generation are no-ops.
//
// Delivery versus consumption: a main follow-up is delivered once the host
// accepts it (SendUserMessage returns). The successor pipeline never waits for
// the model to read it. Consumption is tracked only so a replacement can replay
// a follow-up the host had not consumed.
//
// All watcher state is guarded by watchMu, which stands in for the single
// JavaScript thread: a block that read and wrote state between two awaits in
// the TypeScript holds watchMu here, and every await releases it.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/MichaelKinsy/firstmate-pig-extension/lib"
)

const (
	repairOnlyHint      = "call fm_watch_arm_pi again only after a later notification says the cycle is missing, failed, or unhealthy"
	shuttingDownMessage = "watcher: not armed - Pi session is shutting down"
)

// watchHost is the host surface the watcher drives. sdk.Context satisfies it.
type watchHost interface {
	SendUserMessage(content any, deliverAs string) error
}

type armResult struct {
	OK      bool   `json:"ok"`
	Message string `json:"message"`
}

type closeClassification struct {
	kind    string
	message string
}

type armRecovery struct {
	generation string
	watcherPid string
}

type unconsumedWake struct {
	token   string
	content string
	pending *pendingActionable
}

type deferredClose struct {
	message           string
	predecessorArmPid string
}

type watchGeneration struct {
	id             int
	stopping       bool
	replacement    bool
	child          *armChild
	retryTimer     *time.Timer
	cleanupTimer   *time.Timer
	retryFailures  int
	restoring      bool
	seq            int
	pending        []*pendingActionable
	cleanupFailure string
	// unconsumed lists accepted main follow-ups in acceptance order. It is never
	// cleared at shutdown: a delivery continuation that runs after replacement
	// began reads it to tell a main-queued wake (replayed) from a branch-handled
	// one (finished).
	unconsumed    []*unconsumedWake
	deferredClose *deferredClose
}

// armChild is one `fm-watch-arm.sh --restart` process and everything observed
// from it. Every field is guarded by watchMu except the channels' own sends.
type armChild struct {
	cmd         *exec.Cmd
	pid         string
	stdout      strings.Builder
	stderr      strings.Builder
	readyOnce   bool
	ready       bool
	readyCh     chan struct{}
	closedCh    chan struct{}
	retired     bool
	recovery    *armRecovery
	pending     *pendingActionable
	closeSeen   bool
	verified    bool
	finalStatus *int
}

var (
	watchMu               sync.Mutex
	activeWatchGeneration *watchGeneration
	retiringGenerations   = map[*watchGeneration]struct{}{}
)

// watcher is one Firstmate watcher bridge: the per-factory closure of the
// TypeScript extension.
type watcher struct {
	fmHome, fmRoot, state, config string
	armScript, marker             string
	handoffDir, actionableHandoff string
	version                       string
	retryBase, retryMax           time.Duration
	retryLimit                    int
	armReadyTimeout               time.Duration
	armRetireTimeout              time.Duration
	coord                         *replacementCoordinator
	bus                           *eventBus

	host          watchHost
	generation    *watchGeneration
	nextHandoffID int
	bg            sync.WaitGroup
	closing       bool
}

func positiveInteger(name string, fallback int) int {
	value, err := strconv.ParseFloat(strings.TrimSpace(os.Getenv(name)), 64)
	if err != nil || math.IsNaN(value) || math.IsInf(value, 0) || value <= 0 {
		return fallback
	}
	return int(math.Floor(value))
}

func newWatcher(root string, bus *eventBus) *watcher {
	fmHome := firstNonEmpty(os.Getenv("FM_HOME"), os.Getenv("FM_ROOT_OVERRIDE"), root)
	fmRoot := firstNonEmpty(os.Getenv("FM_ROOT_OVERRIDE"), root)
	state := firstNonEmpty(os.Getenv("FM_STATE_OVERRIDE"), filepath.Join(fmHome, "state"))
	config := firstNonEmpty(os.Getenv("FM_CONFIG_OVERRIDE"), filepath.Join(fmHome, "config"))
	handoffDir := filepath.Join(state, "extensions", "pi-primary-watch")
	readyTimeout := 12000
	if runtime.GOOS == "windows" {
		// Stays above arm's MSYS confirm default (30s in bin/fm-watch-arm.sh) so a
		// slow but successful Git Bash cold start is not SIGTERMed mid-confirmation.
		readyTimeout = 35000
	}
	w := &watcher{
		fmHome: fmHome, fmRoot: fmRoot, state: state, config: config,
		armScript:         filepath.Join(fmRoot, "bin", "fm-watch-arm.sh"),
		marker:            filepath.Join(state, ".pi-watch-extension-loaded"),
		handoffDir:        handoffDir,
		actionableHandoff: filepath.Join(handoffDir, "session-replacement-actionable.json"),
		version:           extensionVersion(fmRoot, "fm-primary-pi-watch.ts"),
		retryBase:         time.Duration(positiveInteger("FM_WATCH_REARM_RETRY_BASE_MS", 250)) * time.Millisecond,
		retryMax:          time.Duration(positiveInteger("FM_WATCH_REARM_RETRY_MAX_MS", 4000)) * time.Millisecond,
		retryLimit:        positiveInteger("FM_WATCH_REARM_RETRY_LIMIT", 5),
		armReadyTimeout:   time.Duration(positiveInteger("FM_PI_ARM_READY_TIMEOUT_MS", readyTimeout)) * time.Millisecond,
		armRetireTimeout:  time.Duration(positiveInteger("FM_WATCH_ARM_RETIRE_TIMEOUT_MS", 1000)) * time.Millisecond,
		bus:               bus,
	}
	w.coord = coordinatorFor(w.actionableHandoff)
	watchMu.Lock()
	w.generation = w.createGenerationLocked()
	activeWatchGeneration = w.generation
	watchMu.Unlock()
	return w
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func (w *watcher) lockOwnership() lockOwnership { return readLockOwnership(w.state) }

func (w *watcher) setHost(host watchHost) {
	watchMu.Lock()
	w.host = host
	watchMu.Unlock()
}

func (w *watcher) currentHost() watchHost {
	watchMu.Lock()
	defer watchMu.Unlock()
	return w.host
}

// --- markers ----------------------------------------------------------------

func (w *watcher) publishGenerationOwner(generation *watchGeneration, phase string) error {
	if w.lockOwnership() == lockOther {
		return nil
	}
	if err := os.MkdirAll(w.state, 0o777); err != nil {
		return err
	}
	temporary := fmt.Sprintf("%s.tmp-%d-%d", w.marker, os.Getpid(), generation.id)
	content := fmt.Sprintf("%s\n%d\ngeneration=%d phase=%s\n", w.version, os.Getpid(), generation.id, phase)
	if err := os.WriteFile(temporary, []byte(content), 0o600); err != nil {
		return err
	}
	return os.Rename(temporary, w.marker)
}

func (w *watcher) retireGenerationOwner(generation *watchGeneration, replacement bool) error {
	data, err := os.ReadFile(w.marker)
	if err != nil {
		return nil
	}
	lines := lineSplitPattern.Split(strings.TrimRight(string(data), " \t\r\n"), -1)
	if len(lines) < 3 || lines[0] != w.version || lines[1] != strconv.Itoa(os.Getpid()) ||
		lines[2] != fmt.Sprintf("generation=%d phase=active", generation.id) {
		return nil
	}
	if replacement {
		return w.publishGenerationOwner(generation, "handoff")
	}
	if err := os.Remove(w.marker); err != nil && errorCode(err) != "ENOENT" {
		return err
	}
	return nil
}

// --- handoff file -----------------------------------------------------------

func (w *watcher) writeReplacementHandoff(pending []*pendingActionable) error {
	if err := os.MkdirAll(w.handoffDir, 0o777); err != nil {
		return err
	}
	w.nextHandoffID++
	temporary := fmt.Sprintf("%s.tmp-%d-%d", w.actionableHandoff, os.Getpid(), w.nextHandoffID)
	var body bytes.Buffer
	encoder := json.NewEncoder(&body)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(replacementHandoffFile{Version: 2, Pending: pending}); err != nil {
		return err
	}
	if err := os.WriteFile(temporary, body.Bytes(), 0o600); err != nil {
		_ = os.Remove(temporary)
		return err
	}
	if err := os.Rename(temporary, w.actionableHandoff); err != nil {
		_ = os.Remove(temporary)
		return err
	}
	return nil
}

func (w *watcher) persistReplacementHandoff(pending []*pendingActionable) error {
	if len(pending) == 0 {
		return nil
	}
	return w.writeReplacementHandoff(pending)
}

func (w *watcher) readStoredHandoff() ([]*pendingActionable, error) {
	data, err := os.ReadFile(w.actionableHandoff)
	if err != nil {
		return nil, err
	}
	return validateReplacementHandoff(data, w.actionableHandoff)
}

func (w *watcher) loadReplacementHandoff() ([]*pendingActionable, error) {
	pending, err := w.readStoredHandoff()
	if err != nil {
		if errorCode(err) == "ENOENT" {
			return nil, nil
		}
		return nil, err
	}
	return pending, nil
}

func (w *watcher) mergeReplacementHandoff(pending *pendingActionable) error {
	stored, err := w.readStoredHandoff()
	if err != nil && errorCode(err) != "ENOENT" {
		return err
	}
	for _, item := range stored {
		if item.Token == pending.Token {
			return w.writeReplacementHandoff(stored)
		}
	}
	return w.writeReplacementHandoff(append(stored, pending))
}

func (w *watcher) clearReplacementHandoff(pending *pendingActionable) error {
	stored, err := w.readStoredHandoff()
	if err != nil {
		if errorCode(err) == "ENOENT" {
			return nil
		}
		return err
	}
	remaining := make([]*pendingActionable, 0, len(stored))
	for _, item := range stored {
		if item.Token != pending.Token {
			remaining = append(remaining, item)
		}
	}
	if len(remaining) == len(stored) {
		return nil
	}
	if len(remaining) > 0 {
		return w.writeReplacementHandoff(remaining)
	}
	if err := os.Remove(w.actionableHandoff); err != nil && errorCode(err) != "ENOENT" {
		return err
	}
	return nil
}

// --- close classification ---------------------------------------------------

func classifyClose(stdout, stderr string, code *int, signal string) closeClassification {
	combined := strings.TrimSpace(stdout + "\n" + stderr)
	if reason := actionableLine(combined); reason != "" {
		return closeClassification{kind: "actionable", message: reason}
	}
	lines := lineSplitPattern.Split(combined, -1)
	for _, line := range lines {
		if healthyLinePattern.MatchString(line) {
			return closeClassification{kind: "failure", message: "watcher: FAILED - Pi extension arm child found an external healthy watcher instead of owning wake delivery\n" + boundedCloseOutput(line)}
		}
	}
	for _, line := range lines {
		if failedLinePattern.MatchString(line) {
			return closeClassification{kind: "failure", message: boundedCloseOutput(line)}
		}
	}
	suffix := ""
	if combined != "" {
		suffix = "\n" + boundedCloseOutput(combined)
	}
	if signal != "" {
		return closeClassification{kind: "failure", message: "watcher: FAILED - Pi extension arm child ended from " + signal + suffix}
	}
	if code != nil && *code != 0 {
		return closeClassification{kind: "failure", message: fmt.Sprintf("watcher: FAILED - fm-watch-arm.sh exited %d%s", *code, suffix)}
	}
	return closeClassification{kind: "failure", message: "watcher: FAILED - Pi extension arm cycle ended without an actionable reason"}
}

// boundedCloseOutput keeps the head of child output a failure message carries
// to main, so a runaway child cannot flood the conversation.
func boundedCloseOutput(output string) string {
	if len(output) <= closeOutputCap {
		return output
	}
	cut := closeOutputCap
	for cut > 0 && !utf8.RuneStart(output[cut]) {
		cut--
	}
	return output[:cut] + "\n[watcher output truncated]"
}

// --- generations ------------------------------------------------------------

func (w *watcher) createGenerationLocked() *watchGeneration {
	w.coord.nextGenID++
	return &watchGeneration{id: w.coord.nextGenID}
}

func generationIsLiveLocked(generation *watchGeneration) bool {
	return activeWatchGeneration == generation && !generation.stopping
}

func (w *watcher) generationIsLive(generation *watchGeneration) bool {
	watchMu.Lock()
	defer watchMu.Unlock()
	return generationIsLiveLocked(generation)
}

func relinquishGenerationLocked(generation *watchGeneration) {
	generation.stopping = true
	if generation.retryTimer != nil {
		generation.retryTimer.Stop()
	}
	if generation.cleanupTimer != nil {
		generation.cleanupTimer.Stop()
	}
	generation.retryTimer, generation.cleanupTimer = nil, nil
	if generation.child != nil {
		retiringGenerations[generation] = struct{}{}
	}
}

func stopGenerationLocked(generation *watchGeneration) *armChild {
	relinquishGenerationLocked(generation)
	child := generation.child
	if child != nil && child.cmd.Process != nil {
		_ = terminateChild(child.cmd.Process)
	}
	generation.child = nil
	delete(retiringGenerations, generation)
	return child
}

func waitClosed(child *armChild, timeout time.Duration) bool {
	if child == nil {
		return true
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-child.closedCh:
		return true
	case <-timer.C:
		return false
	}
}

// stopSessionGeneration is the awaited session_shutdown body.
func (w *watcher) stopSessionGeneration(generation *watchGeneration, replacement bool) error {
	watchMu.Lock()
	generation.replacement = replacement
	watchMu.Unlock()
	if err := w.retireGenerationOwner(generation, replacement); err != nil {
		return err
	}
	if !replacement {
		watchMu.Lock()
		child := stopGenerationLocked(generation)
		watchMu.Unlock()
		waitClosed(child, w.armRetireTimeout)
		return nil
	}
	// A same-process replacement has not proved its successor yet. Keep this
	// generation's established arm child alive while transferring delivery and
	// retry responsibility. The replacement's --restart arm retires it only
	// after the new generation has committed its own tracked child.
	watchMu.Lock()
	relinquishGenerationLocked(generation)
	if generation.child != nil && generation.child.pending != nil {
		observed := generation.child.pending
		known := false
		for _, item := range generation.pending {
			if item.Token == observed.Token {
				known = true
			}
		}
		if !known {
			generation.pending = append(generation.pending, observed)
		}
	}
	pending := append([]*pendingActionable(nil), generation.pending...)
	watchMu.Unlock()
	if len(pending) == 0 {
		return nil
	}
	if err := w.persistReplacementHandoff(pending); err != nil {
		detail := err.Error()
		watchMu.Lock()
		for _, item := range pending {
			if w.coordHasPendingLocked(item.Token) {
				continue
			}
			failed := *item
			failed.Message = item.Message + "\n\nwatcher: FAILED - Pi extension could not persist a replacement-session actionable wake\n" + detail
			w.coord.pending = append(w.coord.pending, &failed)
		}
		watchMu.Unlock()
	}
	return nil
}

func (w *watcher) coordHasPendingLocked(token string) bool {
	for _, item := range w.coord.pending {
		if item.Token == token {
			return true
		}
	}
	return false
}

// shutdownDrain bounds the wait for owned background deliveries at terminal
// shutdown so a host that is itself stopping cannot deadlock the handler.
func (w *watcher) shutdownDrain() {
	done := make(chan struct{})
	go func() { w.bg.Wait(); close(done) }()
	timer := time.NewTimer(w.armRetireTimeout)
	defer timer.Stop()
	select {
	case <-done:
	case <-timer.C:
	}
}

// --- pending actionables ----------------------------------------------------

func (w *watcher) createPendingActionableLocked(message, predecessorArmPid string) *pendingActionable {
	w.coord.nextToken++
	return &pendingActionable{
		Version:           1,
		Token:             fmt.Sprintf("%d-%d-%d", os.Getpid(), time.Now().UnixMilli(), w.coord.nextToken),
		Message:           message,
		PredecessorArmPid: predecessorArmPid,
	}
}

func (w *watcher) goBackground(task func()) {
	watchMu.Lock()
	if w.closing {
		watchMu.Unlock()
		return
	}
	w.bg.Add(1)
	watchMu.Unlock()
	go func() {
		defer w.bg.Done()
		task()
	}()
}

// sendWake delivers one wake to main as an operational follow-up. It returns
// whether the generation is still live once the host accepted the message.
func (w *watcher) sendWake(owner *watchGeneration, message string, pending *pendingActionable) (bool, error) {
	if !w.generationIsLive(owner) {
		return false, nil
	}
	content, err := lib.EncodeOperationalInput(context.Background(), lib.KindWatcher,
		"FIRSTMATE WATCHER WAKE: "+message+"\n\nRun bin/fm-wake-drain.sh first and handle the queued wake. Watcher continuity is extension-owned.")
	if err != nil {
		return false, err
	}
	host := w.currentHost()
	if host == nil {
		return false, fmt.Errorf("watcher: no host session is bound to deliver the wake")
	}
	if pending != nil {
		watchMu.Lock()
		owner.unconsumed = append(owner.unconsumed, &unconsumedWake{token: pending.Token, content: content, pending: pending})
		watchMu.Unlock()
	}
	if err := host.SendUserMessage(content, "followUp"); err != nil {
		if pending != nil {
			watchMu.Lock()
			owner.removeUnconsumedLocked(pending.Token)
			watchMu.Unlock()
		}
		return false, err
	}
	// Accepted by the host. A generation replaced while the host was accepting
	// may have lost the follow-up with the old session, so report it undelivered
	// and let the replacement replay the still-pending record.
	return w.generationIsLive(owner), nil
}

func (g *watchGeneration) removeUnconsumedLocked(token string) {
	for i, wake := range g.unconsumed {
		if wake.token == token {
			g.unconsumed = append(g.unconsumed[:i:i], g.unconsumed[i+1:]...)
			return
		}
	}
}

func (g *watchGeneration) hasUnconsumedLocked(token string) bool {
	for _, wake := range g.unconsumed {
		if wake.token == token {
			return true
		}
	}
	return false
}

// consumeWake records that the host consumed a main follow-up: an idle main at
// before_agent_start, a streaming main at the user message_start that joins
// the running run.
func (w *watcher) consumeWake(owner *watchGeneration, text string) {
	watchMu.Lock()
	var matched *unconsumedWake
	for _, wake := range owner.unconsumed {
		if wake.content == text {
			matched = wake
			break
		}
	}
	if matched == nil {
		watchMu.Unlock()
		return
	}
	owner.removeUnconsumedLocked(matched.token)
	matched.pending.Delivered = true
	watchMu.Unlock()
	if err := w.finishPendingActionable(owner, matched.pending); err != nil {
		w.surfaceCleanupFailure(owner, err)
		w.schedulePendingCleanup(owner)
	}
}

type handlingDelivery struct {
	ok     bool
	detail string
}

func (w *watcher) confirmHandlingDelivery(recovery armRecovery) handlingDelivery {
	env := append(os.Environ(), "FM_HOME="+w.fmHome, "FM_STATE_OVERRIDE="+w.state, "FM_ROOT_OVERRIDE="+w.fmRoot)
	result := lib.RunCommandAsync(context.Background(), "bash",
		[]string{w.armScript, "--handling-delivered", recovery.generation, "--watcher-pid", recovery.watcherPid},
		lib.ExecOptions{Dir: w.fmRoot, Env: env})
	if result.Status != nil && *result.Status == 0 {
		return handlingDelivery{ok: true}
	}
	status := "none"
	if result.Status != nil {
		status = strconv.Itoa(*result.Status)
	}
	stderr := strings.TrimSpace(result.Stderr)
	detail := fmt.Sprintf("watcher: FAILED - handling delivery confirmation was rejected (status=%s generation=%s watcherPid=%s)", status, recovery.generation, recovery.watcherPid)
	if stderr != "" {
		detail += "\n" + stderr
	}
	return handlingDelivery{detail: detail}
}

func (w *watcher) confirmHandlingDeliveryWithRetry(owner *watchGeneration, recovery armRecovery) handlingDelivery {
	snapshot := func() armRecovery {
		watchMu.Lock()
		defer watchMu.Unlock()
		if owner.child != nil && owner.child.recovery != nil {
			return *owner.child.recovery
		}
		return recovery
	}
	if first := w.confirmHandlingDelivery(snapshot()); first.ok {
		return first
	}
	return w.confirmHandlingDelivery(snapshot())
}

func (w *watcher) deliverActionableWake(owner *watchGeneration, message string, pending *pendingActionable, recovery *armRecovery) (bool, error) {
	if !w.generationIsLive(owner) {
		return false, nil
	}
	if recovery != nil {
		confirmed := w.confirmHandlingDeliveryWithRetry(owner, *recovery)
		if !confirmed.ok {
			if !pidAlive(recovery.watcherPid) {
				watchMu.Lock()
				child := owner.child
				watchMu.Unlock()
				w.retireArm(child)
			}
			return w.sendWake(owner, message+"\n\n"+confirmed.detail, pending)
		}
	}
	return w.sendWake(owner, message, pending)
}

func (w *watcher) surfaceFailure(owner *watchGeneration, message string) {
	w.goBackground(func() {
		// The host owns delivery errors; continuity restoration never waits on prompting.
		_, _ = w.sendWake(owner, message, nil)
	})
}

func (w *watcher) enqueuePendingActionable(owner *watchGeneration, pending *pendingActionable) {
	watchMu.Lock()
	for _, item := range owner.pending {
		if item.Token == pending.Token {
			watchMu.Unlock()
			return
		}
	}
	owner.pending = append(owner.pending, pending)
	late := owner.stopping && owner.replacement
	watchMu.Unlock()
	if !late {
		return
	}
	replacementPending := pending
	if err := w.mergeReplacementHandoff(pending); err != nil {
		failed := *pending
		failed.Message = pending.Message + "\n\nwatcher: FAILED - Pi extension could not persist a late replacement-session actionable wake\n" + err.Error()
		replacementPending = &failed
	}
	watchMu.Lock()
	receiver := w.coord.receiver
	if receiver == nil && replacementPending != pending {
		w.coord.pending = append(w.coord.pending, replacementPending)
	}
	watchMu.Unlock()
	if receiver != nil {
		receiver(replacementPending)
	}
}

func (w *watcher) finishPendingActionable(owner *watchGeneration, pending *pendingActionable) error {
	if err := w.clearReplacementHandoff(pending); err != nil {
		return err
	}
	watchMu.Lock()
	for i, item := range owner.pending {
		if item.Token == pending.Token {
			owner.pending = append(owner.pending[:i:i], owner.pending[i+1:]...)
			break
		}
	}
	owner.cleanupFailure = ""
	watchMu.Unlock()
	return nil
}

func (w *watcher) surfaceCleanupFailure(owner *watchGeneration, err error) {
	detail := err.Error()
	watchMu.Lock()
	if owner.cleanupFailure == detail {
		watchMu.Unlock()
		return
	}
	owner.cleanupFailure = detail
	watchMu.Unlock()
	w.surfaceFailure(owner, "watcher: FAILED - Pi extension could not clear a delivered replacement-session actionable wake\n"+detail)
}

func (w *watcher) schedulePendingCleanup(owner *watchGeneration) {
	watchMu.Lock()
	defer watchMu.Unlock()
	if !generationIsLiveLocked(owner) || owner.cleanupTimer != nil {
		return
	}
	var timer *time.Timer
	timer = time.AfterFunc(w.retryDelay(1), func() {
		watchMu.Lock()
		if owner.cleanupTimer == timer {
			owner.cleanupTimer = nil
		}
		watchMu.Unlock()
		w.goBackground(func() { w.processPendingActionables(owner) })
	})
	owner.cleanupTimer = timer
}

func (w *watcher) retryDelay(attempt int) time.Duration {
	exponent := attempt - 1
	if exponent < 0 {
		exponent = 0
	}
	delay := w.retryBase
	for i := 0; i < exponent && delay < w.retryMax; i++ {
		delay *= 2
	}
	return min(delay, w.retryMax)
}

func newClaim(owner *watchGeneration) *deliveryClaim {
	return &deliveryClaim{owner: owner, done: make(chan struct{})}
}

// processPendingActionables drains the owner's pending actionable closes.
func (w *watcher) processPendingActionables(owner *watchGeneration) {
	watchMu.Lock()
	if !generationIsLiveLocked(owner) || owner.restoring || len(owner.pending) == 0 {
		watchMu.Unlock()
		return
	}
	owner.restoring = true
	watchMu.Unlock()
	attemptedCleanup := map[string]bool{}
	defer w.finishProcessing(owner)
	for {
		watchMu.Lock()
		if !generationIsLiveLocked(owner) || len(owner.pending) == 0 {
			watchMu.Unlock()
			return
		}
		var deliveredNow []*pendingActionable
		for _, item := range owner.pending {
			if item.Delivered && !attemptedCleanup[item.Token] {
				deliveredNow = append(deliveredNow, item)
			}
		}
		watchMu.Unlock()
		for _, delivered := range deliveredNow {
			attemptedCleanup[delivered.Token] = true
			if err := w.finishPendingActionable(owner, delivered); err != nil {
				w.surfaceCleanupFailure(owner, err)
			}
		}
		// A record the host has accepted but not consumed is neither redelivered
		// nor finished here: consumption finishes it, replacement replays it.
		watchMu.Lock()
		var pending *pendingActionable
		for _, item := range owner.pending {
			if !item.Delivered && !owner.hasUnconsumedLocked(item.Token) {
				pending = item
				break
			}
		}
		if pending == nil {
			watchMu.Unlock()
			return
		}
		existing := w.coord.deliveries[pending.Token]
		watchMu.Unlock()
		if existing != nil && existing.owner != owner {
			settlement := existing.wait()
			if !w.generationIsLive(owner) {
				return
			}
			if settlement == "delivered" {
				watchMu.Lock()
				pending.Delivered = true
				watchMu.Unlock()
				continue
			}
			watchMu.Lock()
			if w.coord.deliveries[pending.Token] == existing {
				delete(w.coord.deliveries, pending.Token)
			}
			watchMu.Unlock()
		}
		claim := newClaim(owner)
		watchMu.Lock()
		w.coord.deliveries[pending.Token] = claim
		// A new restoration supersedes whatever became of the previous
		// successor; only a failure during this delivery is retried after it.
		owner.deferredClose = nil
		watchMu.Unlock()
		release := func() {
			watchMu.Lock()
			if w.coord.deliveries[pending.Token] == claim {
				delete(w.coord.deliveries, pending.Token)
			}
			watchMu.Unlock()
		}
		restoration, err := w.restoreAfterActionableClose(owner, pending.PredecessorArmPid)
		if err != nil {
			claim.settle("failed")
			release()
			w.surfaceFailure(owner, "watcher: FAILED - Pi extension could not deliver an actionable wake\n"+err.Error())
			return
		}
		if !w.generationIsLive(owner) {
			claim.settle("failed")
			release()
			return
		}
		message := pending.Message
		if restoration.failure != "" {
			message += "\n\n" + restoration.failure
		}
		delivered, err := w.deliverActionableWake(owner, message, pending, restoration.recovery)
		if err != nil {
			claim.settle("failed")
			release()
			w.surfaceFailure(owner, "watcher: FAILED - Pi extension could not deliver an actionable wake\n"+err.Error())
			return
		}
		if !delivered {
			claim.settle("failed")
			release()
			return
		}
		watchMu.Lock()
		awaiting := owner.hasUnconsumedLocked(pending.Token)
		live := generationIsLiveLocked(owner)
		watchMu.Unlock()
		if awaiting && !live {
			// The host accepted the follow-up, then the session was replaced before
			// this continuation ran: the shutdown persisted the still-pending
			// record, so a replacement waiting on this claim must replay it.
			claim.settle("failed")
			release()
			return
		}
		claim.settle("delivered")
		if !awaiting {
			// The branch handled it, or the host consumed it before this ran.
			watchMu.Lock()
			pending.Delivered = true
			watchMu.Unlock()
			if err := w.finishPendingActionable(owner, pending); err != nil {
				w.surfaceCleanupFailure(owner, err)
			}
		}
		release()
	}
}

func (w *watcher) finishProcessing(owner *watchGeneration) {
	watchMu.Lock()
	if !generationIsLiveLocked(owner) {
		watchMu.Unlock()
		return
	}
	owner.restoring = false
	hasDelivered := false
	for _, item := range owner.pending {
		if item.Delivered {
			hasDelivered = true
		}
	}
	deferred := owner.deferredClose
	owner.deferredClose = nil
	retry := deferred != nil && owner.child == nil && owner.retryTimer == nil
	watchMu.Unlock()
	if hasDelivered {
		w.schedulePendingCleanup(owner)
	}
	// No bare arm is launched here. A generation without a child at this point
	// has either delivered a typed restoration failure after its bounded
	// retries, which hands repair to main through fm_watch_arm_pi, or lost a
	// verified successor during the delivery, which takes the ordinary bounded,
	// lock-checked retry it would have taken had the pipeline been idle.
	if retry {
		w.scheduleRetry(owner, deferred.message, deferred.predecessorArmPid)
	}
}

func (w *watcher) receiveReplacementActionable(pending *pendingActionable) {
	watchMu.Lock()
	generation := w.generation
	live := generationIsLiveLocked(generation)
	watchMu.Unlock()
	if !live {
		return
	}
	w.enqueuePendingActionable(generation, pending)
	w.goBackground(func() { w.processPendingActionables(generation) })
}

// --- arm child --------------------------------------------------------------

func (w *watcher) waitForReadiness(child *armChild) bool {
	timer := time.NewTimer(w.armReadyTimeout)
	defer timer.Stop()
	select {
	case <-child.readyCh:
		watchMu.Lock()
		defer watchMu.Unlock()
		return child.ready
	case <-timer.C:
		return false
	}
}

func (w *watcher) retireArm(child *armChild) bool {
	if child == nil {
		return true
	}
	watchMu.Lock()
	child.retired = true
	watchMu.Unlock()
	if child.cmd.Process != nil {
		_ = terminateChild(child.cmd.Process)
	}
	return waitClosed(child, w.armRetireTimeout)
}

type restoration struct {
	failure  string
	recovery *armRecovery
}

func (w *watcher) restoreAfterActionableClose(owner *watchGeneration, predecessorArmPid string) (restoration, error) {
	failure := ""
	for attempt := 0; attempt <= w.retryLimit; attempt++ {
		if !w.generationIsLive(owner) {
			return restoration{}, nil
		}
		replacement, err := w.startArm(owner, predecessorArmPid)
		if err != nil {
			return restoration{}, err
		}
		watchMu.Lock()
		successor := owner.child
		watchMu.Unlock()
		if replacement.OK && successor != nil && w.waitForReadiness(successor) {
			watchMu.Lock()
			recovery := successor.recovery
			watchMu.Unlock()
			return restoration{recovery: recovery}, nil
		}
		if replacement.OK {
			failure = "watcher: FAILED - Pi extension could not verify a ready successor watcher"
			if !w.retireArm(successor) {
				return restoration{failure: failure + fmt.Sprintf("\nwatcher: FAILED - Pi extension could not restore watcher continuity because the unready successor arm did not exit within %dms", w.armRetireTimeout.Milliseconds())}, nil
			}
		} else {
			if readOnlyOrNoSessionRegexp.MatchString(replacement.Message) {
				return restoration{failure: "watcher: FAILED - Pi extension cannot restore continuity because this session no longer owns the lock\n" + replacement.Message +
					fmt.Sprintf("\nwatcher: FAILED - Pi extension could not restore watcher continuity after %d retries", w.retryLimit)}, nil
			}
			failure = "watcher: FAILED - Pi extension could not start the successor watcher cycle\n" + replacement.Message
		}
		if attempt == w.retryLimit {
			break
		}
		time.Sleep(w.retryDelay(attempt + 1))
	}
	return restoration{failure: failure + fmt.Sprintf("\nwatcher: FAILED - Pi extension could not restore watcher continuity after %d retries", w.retryLimit)}, nil
}

func (w *watcher) scheduleRetry(owner *watchGeneration, message, predecessorArmPid string) {
	watchMu.Lock()
	if !generationIsLiveLocked(owner) || owner.child != nil || owner.retryTimer != nil {
		watchMu.Unlock()
		return
	}
	watchMu.Unlock()
	if w.lockOwnership() != lockOwned {
		w.surfaceFailure(owner, "watcher: FAILED - Pi extension cannot restore continuity because this session no longer owns the lock\n"+message)
		return
	}
	watchMu.Lock()
	owner.retryFailures++
	if owner.retryFailures > w.retryLimit {
		watchMu.Unlock()
		w.surfaceFailure(owner, fmt.Sprintf("watcher: FAILED - Pi extension could not restore watcher continuity after %d retries\n%s", w.retryLimit, message))
		return
	}
	var timer *time.Timer
	timer = time.AfterFunc(w.retryDelay(owner.retryFailures), func() {
		watchMu.Lock()
		if owner.retryTimer == timer {
			owner.retryTimer = nil
		}
		live := generationIsLiveLocked(owner)
		watchMu.Unlock()
		if !live {
			return
		}
		result, err := w.startArm(owner, predecessorArmPid)
		if err != nil {
			result = armResult{Message: err.Error()}
		}
		if !result.OK {
			w.surfaceFailure(owner, "watcher: FAILED - Pi extension could not launch a continuity retry\n"+result.Message)
		}
	})
	owner.retryTimer = timer
	watchMu.Unlock()
}

// armOutputCap bounds the output retained per arm-child stream.
const armOutputCap = 1 << 20

// closeOutputCap bounds the child output a failure message forwards to main.
const closeOutputCap = 16 << 10

const armLoginScript = `config_dir="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"; [ -f "$config_dir/x-mode.env" ] && . "$config_dir/x-mode.env"; exec "$FM_WATCH_ARM_SCRIPT" --restart`

func (w *watcher) startArm(owner *watchGeneration, predecessorArmPid string) (armResult, error) {
	if !w.generationIsLive(owner) {
		return armResult{Message: shuttingDownMessage}, nil
	}
	switch w.lockOwnership() {
	case lockOther:
		return armResult{Message: "watcher: read-only - session lock is held by another firstmate session"}, nil
	case lockMissing:
		return armResult{Message: "watcher: not armed - no live session holds the lock; run bin/fm-session-start.sh to reclaim it, then call fm_watch_arm_pi to re-arm"}, nil
	}
	if err := w.publishGenerationOwner(owner, "active"); err != nil {
		return armResult{}, err
	}
	watchMu.Lock()
	if owner.child != nil {
		watchMu.Unlock()
		return armResult{OK: true, Message: "watcher: unchanged - Pi extension already owns an arm child; no manual re-arm needed; " + repairOnlyHint}, nil
	}
	if owner.retryTimer != nil {
		watchMu.Unlock()
		return armResult{OK: true, Message: "watcher: unchanged - Pi extension already owns a scheduled continuity retry; no manual re-arm needed; " + repairOnlyHint}, nil
	}
	owner.seq++
	id := owner.seq
	watchMu.Unlock()

	cmd := exec.Command("bash", "-lc", armLoginScript)
	cmd.Dir = w.fmRoot
	cmd.Env = append(os.Environ(),
		"FM_HOME="+w.fmHome,
		"FM_ROOT_OVERRIDE="+w.fmRoot,
		"FM_CONFIG_OVERRIDE="+w.config,
		"FM_WATCH_ARM_SCRIPT="+w.armScript,
		"FM_WATCH_PREDECESSOR_ARM_PID="+predecessorArmPid,
	)
	detachProcessGroup(cmd)
	child := &armChild{cmd: cmd, readyCh: make(chan struct{}), closedCh: make(chan struct{})}
	stdout, outErr := cmd.StdoutPipe()
	stderr, errErr := cmd.StderrPipe()
	startErr := outErr
	if startErr == nil {
		startErr = errErr
	}
	if startErr == nil {
		startErr = cmd.Start()
	}
	if startErr != nil {
		// Like a Node spawn error, a launch failure arrives as the child's own
		// error event after startArm already reported the child as started.
		watchMu.Lock()
		owner.child = child
		watchMu.Unlock()
		go w.armErrored(owner, child, id, startErr)
		return armResult{OK: true, Message: fmt.Sprintf("watcher: started Pi extension arm child %d; future ordinary re-arms are automatic; %s", id, repairOnlyHint)}, nil
	}
	child.pid = strconv.Itoa(cmd.Process.Pid)
	watchMu.Lock()
	owner.child = child
	watchMu.Unlock()

	var readers sync.WaitGroup
	readers.Add(2)
	go w.readArmStream(owner, child, stdout, true, &readers)
	go w.readArmStream(owner, child, stderr, false, &readers)
	go func() {
		readers.Wait()
		waitErr := cmd.Wait()
		w.armClosed(owner, child, id, waitErr)
	}()
	return armResult{OK: true, Message: fmt.Sprintf("watcher: started Pi extension arm child %d; future ordinary re-arms are automatic; %s", id, repairOnlyHint)}, nil
}

// armErrored is the child's error event for a process that never started.
func (w *watcher) armErrored(owner *watchGeneration, child *armChild, id int, cause error) {
	watchMu.Lock()
	if child.closeSeen {
		watchMu.Unlock()
		return
	}
	child.closeSeen = true
	close(child.closedCh)
	w.settleReadinessLocked(child, false)
	if owner.child == child {
		owner.child = nil
	}
	if owner.child == nil {
		delete(retiringGenerations, owner)
	}
	if !generationIsLiveLocked(owner) || owner.restoring {
		watchMu.Unlock()
		return
	}
	watchMu.Unlock()
	w.scheduleRetry(owner, fmt.Sprintf("watcher: FAILED - Pi extension arm child %d failed: %s", id, cause.Error()), child.pid)
}

func (w *watcher) readArmStream(owner *watchGeneration, child *armChild, source interface{ Read([]byte) (int, error) }, isStdout bool, readers *sync.WaitGroup) {
	defer readers.Done()
	buffer := make([]byte, 4096)
	for {
		count, err := source.Read(buffer)
		if count > 0 {
			watchMu.Lock()
			target := &child.stderr
			if isStdout {
				target = &child.stdout
			}
			// The arm script prints a handful of lines; a runaway child must not
			// grow this process without bound. Output past the cap is dropped.
			if room := armOutputCap - target.Len(); room > 0 {
				target.Write(buffer[:min(count, room)])
			}
			w.observeEstablishedArmLocked(child)
			watchMu.Unlock()
		}
		if err != nil {
			return
		}
	}
}

func (w *watcher) settleReadinessLocked(child *armChild, ready bool) {
	if child.readyOnce {
		return
	}
	child.readyOnce = true
	child.ready = ready
	child.verified = ready
	close(child.readyCh)
}

func (w *watcher) observeEstablishedArmLocked(child *armChild) {
	stdout, stderr := child.stdout.String(), child.stderr.String()
	combined := jsLines(stdout + "\n" + stderr)
	if match := startedRecoveryPattern.FindStringSubmatch(combined); match != nil {
		child.recovery = &armRecovery{watcherPid: match[1], generation: match[2]}
	}
	if startedOrAttachedPattern.MatchString(combined) {
		w.settleReadinessLocked(child, true)
	}
	reason := completedActionableLine(stdout)
	if reason == "" {
		reason = completedActionableLine(stderr)
	}
	if reason != "" && child.pending == nil {
		child.pending = w.createPendingActionableLocked(reason, child.pid)
	}
}

// armClosed is the child's close event: exactly one per child.
func (w *watcher) armClosed(owner *watchGeneration, child *armChild, id int, waitErr error) {
	code, signal := exitDetails(child.cmd.ProcessState)
	watchMu.Lock()
	if child.closeSeen {
		watchMu.Unlock()
		return
	}
	child.closeSeen = true
	close(child.closedCh)
	w.settleReadinessLocked(child, false)
	if owner.child == child {
		owner.child = nil
	}
	if owner.child == nil {
		delete(retiringGenerations, owner)
	}
	classification := classifyClose(child.stdout.String(), child.stderr.String(), code, signal)
	predecessor := child.pid
	if classification.kind == "actionable" {
		pending := child.pending
		if pending == nil {
			pending = w.createPendingActionableLocked(classification.message, predecessor)
		}
		watchMu.Unlock()
		w.enqueuePendingActionable(owner, pending)
		watchMu.Lock()
		live := generationIsLiveLocked(owner)
		if live {
			owner.retryFailures = 0
		}
		watchMu.Unlock()
		if live {
			w.goBackground(func() { w.processPendingActionables(owner) })
		}
		return
	}
	if !generationIsLiveLocked(owner) {
		watchMu.Unlock()
		return
	}
	if owner.restoring {
		// The pipeline is still delivering the wake this successor was started
		// for. A verified successor that failed on its own keeps its bounded
		// retry for the end of that delivery; an unready child closing here was
		// retired by the restoration itself.
		if child.verified && !child.retired {
			owner.deferredClose = &deferredClose{message: classification.message, predecessorArmPid: predecessor}
		}
		watchMu.Unlock()
		return
	}
	watchMu.Unlock()
	w.scheduleRetry(owner, classification.message, predecessor)
}

func (w *watcher) activateOwnedWatch(owner *watchGeneration) (armResult, error) {
	if !w.generationIsLive(owner) {
		return armResult{Message: shuttingDownMessage}, nil
	}
	if w.lockOwnership() != lockOwned {
		return w.startArm(owner, "")
	}
	watchMu.Lock()
	w.coord.receiver, w.coord.receiverOwner = w.receiveReplacementActionable, w
	watchMu.Unlock()
	pending, loadErr := w.loadReplacementHandoff()
	loadFailure := ""
	if loadErr != nil {
		loadFailure = "watcher: FAILED - Pi extension could not load a replacement-session actionable wake\n" + loadErr.Error()
	}
	watchMu.Lock()
	inProcess := w.coord.pending
	w.coord.pending = nil
	watchMu.Unlock()
	for _, actionable := range append(append([]*pendingActionable(nil), pending...), inProcess...) {
		w.enqueuePendingActionable(owner, actionable)
	}
	watchMu.Lock()
	hasPending := len(owner.pending) > 0
	firstPredecessor := ""
	if hasPending {
		firstPredecessor = owner.pending[0].PredecessorArmPid
	}
	watchMu.Unlock()
	if hasPending {
		if loadFailure != "" {
			w.surfaceFailure(owner, loadFailure)
		}
		result, err := w.startArm(owner, firstPredecessor)
		if err != nil {
			return armResult{}, err
		}
		if !result.OK {
			w.surfaceFailure(owner, "watcher: FAILED - Pi extension could not arm before replacement wake delivery\n"+result.Message)
		}
		w.goBackground(func() { w.processPendingActionables(owner) })
		return result, nil
	}
	result, err := w.startArm(owner, "")
	if err != nil {
		return armResult{}, err
	}
	if loadFailure != "" {
		w.surfaceFailure(owner, loadFailure+"\n"+result.Message)
	}
	return result, nil
}

// --- host events ------------------------------------------------------------

func userMessageText(content any) string {
	switch value := content.(type) {
	case string:
		return value
	case []any:
		var parts []string
		for _, part := range value {
			if fields, ok := part.(map[string]any); ok && fields["type"] == "text" {
				if text, ok := fields["text"].(string); ok {
					parts = append(parts, text)
				}
			}
		}
		return strings.Join(parts, "\n")
	}
	return ""
}

func (w *watcher) onBeforeAgentStart(prompt string) error {
	watchMu.Lock()
	generation := w.generation
	watchMu.Unlock()
	w.consumeWake(generation, prompt)
	if w.lockOwnership() != lockOwned {
		return nil
	}
	_, err := w.activateOwnedWatch(generation)
	return err
}

func (w *watcher) onMessageStart(message map[string]any) {
	if message["role"] != "user" {
		return
	}
	watchMu.Lock()
	generation := w.generation
	watchMu.Unlock()
	w.consumeWake(generation, userMessageText(message["content"]))
}

func (w *watcher) onSessionStart() error {
	watchMu.Lock()
	if w.generation.stopping {
		w.generation = w.createGenerationLocked()
	}
	w.closing = false
	generation := w.generation
	activeWatchGeneration = generation
	watchMu.Unlock()
	if w.lockOwnership() != lockOwned {
		return nil
	}
	_, err := w.activateOwnedWatch(generation)
	return err
}

func (w *watcher) onSessionShutdown(reason string) error {
	replacement := reason == "reload" || reason == "new" || reason == "resume" || reason == "fork"
	watchMu.Lock()
	generation := w.generation
	if w.coord.receiverOwner == w {
		w.coord.receiver, w.coord.receiverOwner = nil, nil
	}
	watchMu.Unlock()
	err := w.stopSessionGeneration(generation, replacement)
	if !replacement {
		watchMu.Lock()
		w.closing = true
		watchMu.Unlock()
		w.shutdownDrain()
	}
	return err
}

func (w *watcher) arm() (armResult, error) {
	watchMu.Lock()
	generation := w.generation
	watchMu.Unlock()
	return w.activateOwnedWatch(generation)
}

// bindInitialMarker publishes the first generation while the lock may still be
// absent, so session-start can tell a loaded extension from a missing one; a
// foreign live lock still suppresses publication.
func (w *watcher) bindInitialMarker() error {
	watchMu.Lock()
	generation := w.generation
	watchMu.Unlock()
	return w.publishGenerationOwner(generation, "active")
}

// pidFromProcess is used by tests to name an arm child.
func (c *armChild) processID() string { return c.pid }
