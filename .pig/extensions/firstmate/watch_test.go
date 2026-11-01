package firstmate

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
	"unicode/utf8"
)

// fakeHost records the follow-ups the watcher delivers to main.
type fakeHost struct {
	mu       sync.Mutex
	messages []string
	err      error
	accepted chan struct{}
}

func newFakeHost() *fakeHost { return &fakeHost{accepted: make(chan struct{}, 32)} }

func (h *fakeHost) SendUserMessage(content any, deliverAs string) error {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.err != nil {
		return h.err
	}
	text, _ := content.(string)
	h.messages = append(h.messages, deliverAs+"|"+text)
	h.accepted <- struct{}{}
	return nil
}

func (h *fakeHost) sent() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return append([]string(nil), h.messages...)
}

type watchHome struct {
	root, state, bin string
}

// newWatchHome builds a Firstmate home whose lock names this test process and
// whose arm and operational-input scripts are the scenario's own.
func newWatchHome(t *testing.T, armScript string) watchHome {
	t.Helper()
	root := t.TempDir()
	home := watchHome{root: root, state: filepath.Join(root, "state"), bin: filepath.Join(root, "bin")}
	for _, dir := range []string{home.state, home.bin, filepath.Join(root, ".pi", "extensions")} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	write := func(path, content string, mode os.FileMode) {
		if err := os.WriteFile(path, []byte(content), mode); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(home.bin, "fm-watch-arm.sh"), armScript, 0o755)
	write(filepath.Join(home.bin, "fm-operational-input.sh"), "#!/usr/bin/env bash\ninput=$(cat)\nprintf 'ENC[%s]:%s' \"$2\" \"$input\"\n", 0o755)
	write(filepath.Join(root, ".pi", "extensions", "fm-primary-pi-watch.ts"), "// tracked watcher source\n", 0o644)
	write(filepath.Join(home.state, ".lock"), strconv.Itoa(os.Getpid())+"\n", 0o644)
	t.Setenv("FM_HOME", root)
	t.Setenv("FM_ROOT_OVERRIDE", root)
	t.Setenv("FM_STATE_OVERRIDE", home.state)
	t.Setenv("FM_CONFIG_OVERRIDE", filepath.Join(root, "config"))
	t.Setenv("FM_WATCH_REARM_RETRY_BASE_MS", "10")
	t.Setenv("FM_WATCH_REARM_RETRY_MAX_MS", "40")
	t.Setenv("FM_WATCH_REARM_RETRY_LIMIT", "2")
	t.Setenv("FM_PI_ARM_READY_TIMEOUT_MS", "3000")
	t.Setenv("FM_WATCH_ARM_RETIRE_TIMEOUT_MS", "1000")
	return home
}

func eventually(t *testing.T, what string, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func newTestWatcher(t *testing.T, home watchHome, host watchHost) *watcher {
	t.Helper()
	w := newWatcher(home.root, newEventBus())
	w.setHost(host)
	t.Cleanup(func() {
		_ = w.onSessionShutdown("quit")
		watchMu.Lock()
		activeWatchGeneration = nil
		watchMu.Unlock()
	})
	return w
}

// armScriptOnce makes the first invocation close with an actionable signal and
// every later invocation stay established until retired.
const armScriptOnce = `#!/usr/bin/env bash
state="${FM_STATE_OVERRIDE}"
if [ "$1" = "--handling-delivered" ]; then echo "$*" >> "$state/handling-delivered.log"; exit 0; fi
n=$(cat "$state/arm-count" 2>/dev/null || echo 0)
n=$((n+1)); echo "$n" > "$state/arm-count"
echo "$$ predecessor=${FM_WATCH_PREDECESSOR_ARM_PID:-}" >> "$state/arm-starts.log"
echo "watcher: started pid=$$ recovery-generation=gen$n"
if [ "$n" = 1 ]; then
  sleep 0.2
  echo "signal: wake one"
  exit 0
fi
exec sleep 30
`

func TestLockOwnershipRejectsALiveLockOutsideAncestry(t *testing.T) {
	home := newWatchHome(t, armScriptOnce)
	sleeper := exec.Command("sleep", "30")
	if err := sleeper.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sleeper.Process.Kill(); _ = sleeper.Wait() })
	lock := filepath.Join(home.state, ".lock")
	cases := []struct {
		name string
		lock string
		want lockOwnership
	}{
		{"this process", strconv.Itoa(os.Getpid()), lockOwned},
		{"a live unrelated pid", strconv.Itoa(sleeper.Process.Pid), lockOther},
		{"init", "1", lockOther},
		{"malformed", "not-a-pid", lockOther},
		{"a dead pid", "2147483646", lockMissing},
	}
	for _, tc := range cases {
		if err := os.WriteFile(lock, []byte(tc.lock+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		if got := readLockOwnership(home.state); got != tc.want {
			t.Errorf("%s: ownership = %s, want %s", tc.name, got, tc.want)
		}
	}
	if err := os.Remove(lock); err != nil {
		t.Fatal(err)
	}
	if got := readLockOwnership(home.state); got != lockMissing {
		t.Errorf("absent lock: ownership = %s, want %s", got, lockMissing)
	}
}

func TestBeforeAgentStartArmsAfterSessionStartAcquiresTheLock(t *testing.T) {
	home := newWatchHome(t, armScriptOnce)
	lock := filepath.Join(home.state, ".lock")
	if err := os.Remove(lock); err != nil {
		t.Fatal(err)
	}
	w := newTestWatcher(t, home, newFakeHost())
	if err := w.onSessionStart(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(home.state, "arm-count")); !os.IsNotExist(err) {
		t.Fatalf("session_start without a home lock must not arm: %v", err)
	}
	if err := os.WriteFile(lock, []byte(strconv.Itoa(os.Getpid())+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := w.onBeforeAgentStart("first user prompt"); err != nil {
		t.Fatal(err)
	}
	eventually(t, "the first arm after the lock is acquired", func() bool {
		data, err := os.ReadFile(filepath.Join(home.state, "arm-count"))
		return err == nil && strings.TrimSpace(string(data)) == "1"
	})
}

func TestStartArmRefusesWhenAnotherSessionHoldsTheLock(t *testing.T) {
	home := newWatchHome(t, armScriptOnce)
	sleeper := exec.Command("sleep", "30")
	if err := sleeper.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = sleeper.Process.Kill(); _ = sleeper.Wait() })
	if err := os.WriteFile(filepath.Join(home.state, ".lock"), []byte(strconv.Itoa(sleeper.Process.Pid)+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	w := newTestWatcher(t, home, newFakeHost())
	result, err := w.arm()
	if err != nil {
		t.Fatal(err)
	}
	if result.OK || !strings.Contains(result.Message, "watcher: read-only - session lock is held by another firstmate session") {
		t.Fatalf("arm = %+v, want a read-only refusal", result)
	}
	if _, err := os.Stat(filepath.Join(home.state, "arm-count")); err == nil {
		t.Fatal("a non-owning session must never launch the arm script")
	}
	if _, err := os.Stat(filepath.Join(home.state, ".pi-watch-extension-loaded")); err == nil {
		t.Fatal("a foreign live lock must suppress marker publication")
	}
}

func TestMarkerPublishesTrackedVersionAndRetiresByReason(t *testing.T) {
	home := newWatchHome(t, armScriptOnce)
	w := newTestWatcher(t, home, newFakeHost())
	if err := w.bindInitialMarker(); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(home.state, ".pi-watch-extension-loaded")
	data, err := os.ReadFile(marker)
	if err != nil {
		t.Fatal(err)
	}
	version := extensionVersion(home.root, "fm-primary-pi-watch.ts")
	want := version + "\n" + strconv.Itoa(os.Getpid()) + "\ngeneration=" + strconv.Itoa(w.generation.id) + " phase=active\n"
	if string(data) != want {
		t.Fatalf("marker = %q, want %q", data, want)
	}
	if !strings.HasPrefix(version, "sha256:") {
		t.Fatalf("version = %q, want the tracked source digest", version)
	}
	if err := w.retireGenerationOwner(w.generation, true); err != nil {
		t.Fatal(err)
	}
	data, _ = os.ReadFile(marker)
	if !strings.HasSuffix(string(data), "phase=handoff\n") {
		t.Fatalf("replacement retirement left marker %q, want phase=handoff", data)
	}
	if err := w.publishGenerationOwner(w.generation, "active"); err != nil {
		t.Fatal(err)
	}
	if err := w.retireGenerationOwner(w.generation, false); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("terminal retirement left the marker behind: %v", err)
	}
}

func TestClassifyCloseOrdersActionableHealthyFailedSignalAndExit(t *testing.T) {
	code := func(value int) *int { return &value }
	cases := []struct {
		name           string
		stdout, stderr string
		code           *int
		signal         string
		kind, message  string
	}{
		{"actionable in stdout", "noise\nstale: queue\n", "", code(0), "", "actionable", "stale: queue"},
		{"heartbeat with a boundary", "heartbeat\n", "", code(0), "", "actionable", "heartbeat"},
		{"heartbeat word is not a reason", "heartbeating\n", "", code(0), "", "failure", "watcher: FAILED - Pi extension arm cycle ended without an actionable reason"},
		{"healthy external watcher", "watcher: healthy pid=7\n", "", code(0), "", "failure", "watcher: FAILED - Pi extension arm child found an external healthy watcher instead of owning wake delivery\nwatcher: healthy pid=7"},
		{"declared failure", "", "watcher: FAILED - no lock\n", code(1), "", "failure", "watcher: FAILED - no lock"},
		{"signal", "", "", nil, "SIGTERM", "failure", "watcher: FAILED - Pi extension arm child ended from SIGTERM"},
		{"exit code with output", "boom", "", code(7), "", "failure", "watcher: FAILED - fm-watch-arm.sh exited 7\nboom"},
	}
	for _, tc := range cases {
		got := classifyClose(tc.stdout, tc.stderr, tc.code, tc.signal)
		if got.kind != tc.kind || got.message != tc.message {
			t.Errorf("%s: classification = %+v, want kind=%s message=%q", tc.name, got, tc.kind, tc.message)
		}
	}
}

func TestReplacementHandoffSchemaRejectsMalformedRecords(t *testing.T) {
	good := `{"version":2,"pending":[{"version":1,"token":"1-2-3","message":"signal: x","predecessorArmPid":"42"}]}`
	if _, err := validateReplacementHandoff([]byte(good), "handoff.json"); err != nil {
		t.Fatalf("valid handoff rejected: %v", err)
	}
	bad := map[string]string{
		"wrong envelope version":  `{"version":1,"pending":[{"version":1,"token":"1-2-3","message":"signal: x","predecessorArmPid":"4"}]}`,
		"empty pending":           `{"version":2,"pending":[]}`,
		"token shape":             `{"version":2,"pending":[{"version":1,"token":"a-b-c","message":"signal: x","predecessorArmPid":"4"}]}`,
		"non-actionable message":  `{"version":2,"pending":[{"version":1,"token":"1-2-3","message":"hello","predecessorArmPid":"4"}]}`,
		"pid shape":               `{"version":2,"pending":[{"version":1,"token":"1-2-3","message":"signal: x","predecessorArmPid":"x4"}]}`,
		"delivered must be true":  `{"version":2,"pending":[{"version":1,"token":"1-2-3","message":"signal: x","predecessorArmPid":"4","delivered":false}]}`,
		"duplicate tokens":        `{"version":2,"pending":[{"version":1,"token":"1-2-3","message":"signal: x","predecessorArmPid":"4"},{"version":1,"token":"1-2-3","message":"stale: y","predecessorArmPid":"5"}]}`,
		"record is not an object": `{"version":2,"pending":[7]}`,
	}
	for name, body := range bad {
		_, err := validateReplacementHandoff([]byte(body), "handoff.json")
		if err == nil || !strings.Contains(err.Error(), "invalid Pi replacement actionable handoff at handoff.json") {
			t.Errorf("%s: err = %v, want the invalid-handoff error", name, err)
		}
	}
}

func TestReplacementHandoffMatchesTheStoredSchemaExactly(t *testing.T) {
	const record = `{"version":1,"token":"1-2-3","message":"signal: x","predecessorArmPid":"4"}`
	accepted := map[string]string{
		"numeric versions written as 1.0 and 2.0": `{"version":2.0,"pending":[{"version":1.0,"token":"1-2-3","message":"signal: x","predecessorArmPid":""}]}`,
		"unknown members are ignored":             `{"version":2,"extra":true,"pending":[` + record + `]}`,
	}
	for name, body := range accepted {
		if _, err := validateReplacementHandoff([]byte(body), "h.json"); err != nil {
			t.Errorf("%s: rejected: %v", name, err)
		}
	}
	rejected := map[string]string{
		"keys fold case in encoding/json but not in the schema": `{"version":2,"pending":[{"version":1,"TOKEN":"1-2-3","message":"signal: x","predecessorArmPid":"4"}]}`,
		"envelope key case":         `{"Version":2,"pending":[` + record + `]}`,
		"pending key case":          `{"version":2,"Pending":[` + record + `]}`,
		"string version":            `{"version":"2","pending":[` + record + `]}`,
		"delivered null":            `{"version":2,"pending":[{"version":1,"token":"1-2-3","message":"signal: x","predecessorArmPid":"4","delivered":null}]}`,
		"message of the wrong type": `{"version":2,"pending":[{"version":1,"token":"1-2-3","message":["signal: x"],"predecessorArmPid":"4"}]}`,
		"pending is not an array":   `{"version":2,"pending":{}}`,
		"top level array":           `[1]`,
	}
	for name, body := range rejected {
		_, err := validateReplacementHandoff([]byte(body), "h.json")
		if err == nil {
			t.Errorf("%s: accepted, want rejection", name)
		}
	}
}

func TestFailureMessagesBoundTheChildOutputTheyForwardToMain(t *testing.T) {
	flood := strings.Repeat("x", closeOutputCap*3)
	code := 9
	got := classifyClose(flood, "", &code, "")
	if len(got.message) > closeOutputCap+200 || !strings.HasSuffix(got.message, "[watcher output truncated]") {
		t.Fatalf("failure message is %d bytes and ends %q; want a bounded, marked truncation", len(got.message), got.message[len(got.message)-40:])
	}
	if !strings.HasPrefix(got.message, "watcher: FAILED - fm-watch-arm.sh exited 9\nxxx") {
		t.Fatalf("failure message lost its leading classification: %q", got.message[:60])
	}
	multibyte := strings.Repeat("é", closeOutputCap)
	if cut := boundedCloseOutput(multibyte); !utf8.ValidString(cut) {
		t.Fatal("truncation split a multibyte rune")
	}
}

func TestHandoffFileMergeClearAndDeliveredFlag(t *testing.T) {
	home := newWatchHome(t, armScriptOnce)
	w := newTestWatcher(t, home, newFakeHost())
	first := &pendingActionable{Version: 1, Token: "1-1-1", Message: "signal: a", PredecessorArmPid: "10"}
	second := &pendingActionable{Version: 1, Token: "1-1-2", Message: "stale: b", PredecessorArmPid: "11", Delivered: true}
	if err := w.mergeReplacementHandoff(first); err != nil {
		t.Fatal(err)
	}
	if err := w.mergeReplacementHandoff(first); err != nil {
		t.Fatal(err)
	}
	if err := w.mergeReplacementHandoff(second); err != nil {
		t.Fatal(err)
	}
	loaded, err := w.loadReplacementHandoff()
	if err != nil || len(loaded) != 2 || loaded[0].Token != "1-1-1" || !loaded[1].Delivered {
		t.Fatalf("loaded = %+v err=%v, want two records with the second delivered", loaded, err)
	}
	info, err := os.Stat(w.actionableHandoff)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("handoff mode = %v err=%v, want 0600", info.Mode().Perm(), err)
	}
	var onDisk struct {
		Version int `json:"version"`
	}
	raw, _ := os.ReadFile(w.actionableHandoff)
	if err := json.Unmarshal(raw, &onDisk); err != nil || onDisk.Version != 2 {
		t.Fatalf("handoff body %q does not carry the version-2 envelope", raw)
	}
	if err := w.clearReplacementHandoff(first); err != nil {
		t.Fatal(err)
	}
	if err := w.clearReplacementHandoff(second); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(w.actionableHandoff); !os.IsNotExist(err) {
		t.Fatalf("clearing the last record must remove the handoff file: %v", err)
	}
	if err := w.clearReplacementHandoff(first); err != nil {
		t.Fatalf("clearing from an absent handoff must be a no-op: %v", err)
	}
	if err := os.MkdirAll(w.handoffDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(w.actionableHandoff, []byte("{broken"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := w.loadReplacementHandoff(); err == nil {
		t.Fatal("a corrupt handoff must surface as a load failure, not be treated as empty")
	}
}

func TestActionableCloseRestoresWatcherAndDeliversWakeOnce(t *testing.T) {
	home := newWatchHome(t, armScriptOnce)
	host := newFakeHost()
	w := newTestWatcher(t, home, host)
	if err := w.onSessionStart(); err != nil {
		t.Fatal(err)
	}
	eventually(t, "the wake follow-up", func() bool { return len(host.sent()) == 1 })
	sent := host.sent()[0]
	if !strings.HasPrefix(sent, "followUp|ENC[watcher]:FIRSTMATE WATCHER WAKE: signal: wake one") {
		t.Fatalf("delivered %q, want the encoded watcher wake as a follow-up", sent)
	}
	if !strings.Contains(sent, "Run bin/fm-wake-drain.sh first") {
		t.Fatalf("delivered %q, want the drain instruction", sent)
	}
	starts, _ := os.ReadFile(filepath.Join(home.state, "arm-starts.log"))
	lines := strings.Split(strings.TrimSpace(string(starts)), "\n")
	if len(lines) != 2 {
		t.Fatalf("arm starts = %q, want the original arm and one successor", starts)
	}
	firstPid := strings.Fields(lines[0])[0]
	if !strings.HasSuffix(lines[1], "predecessor="+firstPid) {
		t.Fatalf("successor start %q must name the predecessor arm pid %s", lines[1], firstPid)
	}
	confirmed, _ := os.ReadFile(filepath.Join(home.state, "handling-delivered.log"))
	if !strings.Contains(string(confirmed), "--handling-delivered gen2 --watcher-pid") {
		t.Fatalf("handling delivery confirmation = %q, want the successor's recovery generation", confirmed)
	}
	// The pending record stays until the host consumes the follow-up.
	content := strings.TrimPrefix(sent, "followUp|")
	w.onBeforeAgentStart(content)
	eventually(t, "the consumed record to leave the owner", func() bool {
		watchMu.Lock()
		defer watchMu.Unlock()
		return len(w.generation.pending) == 0
	})
	if _, err := os.Stat(w.actionableHandoff); !os.IsNotExist(err) {
		t.Fatalf("handoff file still present after consumption: %v", err)
	}
	if got := len(host.sent()); got != 1 {
		t.Fatalf("the wake was delivered %d times, want exactly once", got)
	}
}

func TestStreamingMainConsumesWakeAtMessageStart(t *testing.T) {
	home := newWatchHome(t, armScriptOnce)
	host := newFakeHost()
	w := newTestWatcher(t, home, host)
	if err := w.onSessionStart(); err != nil {
		t.Fatal(err)
	}
	eventually(t, "the wake follow-up", func() bool { return len(host.sent()) == 1 })
	content := strings.TrimPrefix(host.sent()[0], "followUp|")
	w.onMessageStart(map[string]any{"role": "assistant", "content": content})
	watchMu.Lock()
	stillPending := len(w.generation.pending)
	watchMu.Unlock()
	if stillPending != 1 {
		t.Fatalf("an assistant message must not consume the wake; %d records pending", stillPending)
	}
	w.onMessageStart(map[string]any{"role": "user", "content": []any{map[string]any{"type": "text", "text": content}}})
	eventually(t, "message_start consumption", func() bool {
		watchMu.Lock()
		defer watchMu.Unlock()
		return len(w.generation.pending) == 0
	})
}

func TestReplacementShutdownRetainsChildAndHandsPendingWakeToTheSuccessor(t *testing.T) {
	home := newWatchHome(t, armScriptOnce)
	host := newFakeHost()
	host.err = os.ErrClosed // main cannot accept: the wake stays pending and unconsumed
	w := newTestWatcher(t, home, host)
	if err := w.onSessionStart(); err != nil {
		t.Fatal(err)
	}
	eventually(t, "the actionable close to be recorded", func() bool {
		watchMu.Lock()
		defer watchMu.Unlock()
		return len(w.generation.pending) == 1 && w.generation.child != nil
	})
	watchMu.Lock()
	child := w.generation.child
	watchMu.Unlock()
	if err := w.onSessionShutdown("reload"); err != nil {
		t.Fatal(err)
	}
	if child.cmd.Process == nil || !pidAlive(child.pid) {
		t.Fatal("a replacement shutdown must retain the established arm child")
	}
	data, err := os.ReadFile(w.actionableHandoff)
	if err != nil {
		t.Fatalf("replacement shutdown did not persist the pending wake: %v", err)
	}
	records, err := validateReplacementHandoff(data, w.actionableHandoff)
	if err != nil || len(records) != 1 || !strings.HasPrefix(records[0].Message, "signal: wake one") {
		t.Fatalf("handoff = %s err=%v, want the pending signal close", data, err)
	}
	marker, _ := os.ReadFile(filepath.Join(home.state, ".pi-watch-extension-loaded"))
	if !strings.HasSuffix(string(marker), "phase=handoff\n") {
		t.Fatalf("marker = %q, want phase=handoff while the successor is unproven", marker)
	}

	successorHost := newFakeHost()
	successor := newWatcher(home.root, newEventBus())
	successor.setHost(successorHost)
	t.Cleanup(func() { _ = successor.onSessionShutdown("quit") })
	if err := successor.onSessionStart(); err != nil {
		t.Fatal(err)
	}
	eventually(t, "the successor to replay the handoff wake", func() bool { return len(successorHost.sent()) == 1 })
	if !strings.Contains(successorHost.sent()[0], "signal: wake one") {
		t.Fatalf("successor delivered %q, want the handed-off wake", successorHost.sent()[0])
	}
}

func TestFailedArmRetriesThenSurfacesTheFailureToMain(t *testing.T) {
	script := `#!/usr/bin/env bash
echo "$$" >> "${FM_STATE_OVERRIDE}/failing-arm.log"
echo "watcher: FAILED - lock busy"
exit 1
`
	home := newWatchHome(t, script)
	host := newFakeHost()
	w := newTestWatcher(t, home, host)
	if err := w.onSessionStart(); err != nil {
		t.Fatal(err)
	}
	eventually(t, "the retry budget to be exhausted", func() bool { return len(host.sent()) == 1 })
	if !strings.Contains(host.sent()[0], "watcher: FAILED - Pi extension could not restore watcher continuity after 2 retries\nwatcher: FAILED - lock busy") {
		t.Fatalf("surfaced %q, want the bounded-retry failure with the last close", host.sent()[0])
	}
	log, _ := os.ReadFile(filepath.Join(home.state, "failing-arm.log"))
	if got := len(strings.Fields(string(log))); got != 3 {
		t.Fatalf("arm launched %d times, want the initial launch plus 2 retries", got)
	}
}

func TestTerminalShutdownStopsTheArmChild(t *testing.T) {
	home := newWatchHome(t, armScriptOnce)
	if err := os.WriteFile(filepath.Join(home.state, "arm-count"), []byte("1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	w := newTestWatcher(t, home, newFakeHost())
	if err := w.onSessionStart(); err != nil {
		t.Fatal(err)
	}
	eventually(t, "the established arm child", func() bool {
		watchMu.Lock()
		defer watchMu.Unlock()
		return w.generation.child != nil && w.generation.child.pid != ""
	})
	watchMu.Lock()
	pid := w.generation.child.pid
	watchMu.Unlock()
	if err := w.onSessionShutdown("quit"); err != nil {
		t.Fatal(err)
	}
	eventually(t, "the arm child to exit", func() bool { return !pidAlive(pid) })
	if again, _ := w.arm(); again.OK {
		t.Fatalf("a stopped generation must refuse to arm, got %+v", again)
	}
}

func TestOrdinaryRearmIsUnchangedWhileTheChildLives(t *testing.T) {
	home := newWatchHome(t, armScriptOnce)
	if err := os.WriteFile(filepath.Join(home.state, "arm-count"), []byte("1\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	w := newTestWatcher(t, home, newFakeHost())
	first, err := w.arm()
	if err != nil || !first.OK || !strings.HasPrefix(first.Message, "watcher: started Pi extension arm child 1;") {
		t.Fatalf("first arm = %+v err=%v", first, err)
	}
	eventually(t, "the arm child to establish", func() bool {
		watchMu.Lock()
		defer watchMu.Unlock()
		return w.generation.child != nil && w.generation.child.ready
	})
	second, err := w.arm()
	if err != nil || !second.OK || !strings.HasPrefix(second.Message, "watcher: unchanged - Pi extension already owns an arm child;") {
		t.Fatalf("second arm = %+v err=%v, want unchanged", second, err)
	}
	if !strings.HasSuffix(second.Message, repairOnlyHint) {
		t.Fatalf("unchanged message %q must carry the repair-only hint", second.Message)
	}
}

func TestPositiveIntegerMatchesNumberCoercion(t *testing.T) {
	cases := map[string]int{"": 7, "  25 ": 25, "3.9": 3, "0": 7, "-4": 7, "abc": 7, "1e2": 100, "Infinity": 7}
	for raw, want := range cases {
		t.Setenv("FM_TEST_POSITIVE", raw)
		if got := positiveInteger("FM_TEST_POSITIVE", 7); got != want {
			t.Errorf("positiveInteger(%q) = %d, want %d", raw, got, want)
		}
	}
}
