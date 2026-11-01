package firstmate

// Ports the replacement-session handoff, ownership and marker helpers of
// Firstmate .pi/extensions/fm-primary-pi-watch.ts. The durable handoff file is
// the only state a replacement extension process can rely on: the in-process
// coordinator below additionally serves a replacement that shares this process.

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
)

type lockOwnership string

const (
	lockOwned   lockOwnership = "owned"
	lockMissing lockOwnership = "missing"
	lockOther   lockOwnership = "other"
)

// lockAncestryDepth bounds the parent walk that proves this process descends
// from the harness pid named by the session lock.
const lockAncestryDepth = 8

var decimalPID = regexp.MustCompile(`^[0-9]+$`)

func parentPID(pid string) string {
	output, err := exec.Command("ps", "-o", "ppid=", "-p", pid).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(output))
}

func pidAlive(pid string) bool {
	number, err := strconv.Atoi(pid)
	if err != nil || number <= 0 {
		return false
	}
	process, err := os.FindProcess(number)
	if err != nil {
		return false
	}
	return processAlive(process)
}

// readLockOwnership reports whether this process descends from the pid in the
// session lock. A lock naming a live pid outside this process's ancestry is
// owned by another session, never by this one.
func readLockOwnership(state string) lockOwnership {
	data, err := os.ReadFile(filepath.Join(state, ".lock"))
	if err != nil {
		return lockMissing
	}
	lockPid := strings.TrimSpace(string(data))
	if !decimalPID.MatchString(lockPid) || lockPid == "1" {
		return lockOther
	}
	pid := strconv.Itoa(os.Getpid())
	for i := 0; i < lockAncestryDepth; i++ {
		if pid == lockPid {
			return lockOwned
		}
		pid = parentPID(pid)
		if pid == "" || pid == "1" {
			break
		}
	}
	if pidAlive(lockPid) {
		return lockOther
	}
	return lockMissing
}

// extensionVersion is the marker identity Firstmate's guarded scripts compare
// (bin/fm-wake-lib.sh fm_pi_extension_version): the SHA-256 of the tracked
// extension source the Go port replaces. A home without that tracked source
// publishes an identity no consumer matches, which keeps every consumer loud.
func extensionVersion(root, source string) string {
	data, err := os.ReadFile(filepath.Join(root, ".pi", "extensions", source))
	if err != nil {
		return "go-native:unavailable"
	}
	sum := sha256.Sum256(data)
	return "sha256:" + hex.EncodeToString(sum[:])
}

func errorCode(err error) string {
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return "ENOENT"
	case err == nil:
		return ""
	default:
		return err.Error()
	}
}

// pendingActionable is one actionable watcher close that has not finished
// delivery. Delivered is the only mutable field.
type pendingActionable struct {
	Version           int    `json:"version"`
	Token             string `json:"token"`
	Message           string `json:"message"`
	PredecessorArmPid string `json:"predecessorArmPid"`
	Delivered         bool   `json:"delivered,omitempty"`
}

type replacementHandoffFile struct {
	Version int                  `json:"version"`
	Pending []*pendingActionable `json:"pending"`
}

var (
	pendingTokenPattern       = regexp.MustCompile(`^[0-9]+-[0-9]+-[0-9]+$`)
	predecessorArmPidPattern  = regexp.MustCompile(`^[0-9]*$`)
	actionableLinePattern     = regexp.MustCompile(`^(signal:|stale:|check:|heartbeat($|:))`)
	lineSplitPattern          = regexp.MustCompile(`\r?\n`)
	healthyLinePattern        = regexp.MustCompile(`^watcher: healthy\b`)
	failedLinePattern         = regexp.MustCompile(`^watcher: FAILED`)
	startedRecoveryPattern    = regexp.MustCompile(`(?m)^watcher: started pid=([0-9]+).* recovery-generation=([A-Za-z0-9._-]+)$`)
	startedOrAttachedPattern  = regexp.MustCompile(`(?m)^watcher: (?:started|attached)\b`)
	readOnlyOrNoSessionRegexp = regexp.MustCompile(`(?:read-only|no live session)`)
)

// jsLines rewrites every JavaScript line terminator to a newline so multiline
// patterns match the same lines Node's regular expressions would.
func jsLines(text string) string {
	return strings.NewReplacer("\r\n", "\n", "\r", "\n", " ", "\n", " ", "\n").Replace(text)
}

func actionableLine(output string) string {
	for _, line := range lineSplitPattern.Split(output, -1) {
		if actionableLinePattern.MatchString(line) {
			return line
		}
	}
	return ""
}

func completedActionableLine(output string) string {
	newline := strings.LastIndex(output, "\n")
	if newline < 0 {
		return ""
	}
	return actionableLine(output[:newline+1])
}

func invalidHandoff(path string) error {
	return fmt.Errorf("invalid Pi replacement actionable handoff at %s", path)
}

func validatePendingActionable(item *pendingActionable, path string) error {
	if item == nil || item.Version != 1 || !pendingTokenPattern.MatchString(item.Token) ||
		actionableLine(item.Message) == "" || !predecessorArmPidPattern.MatchString(item.PredecessorArmPid) {
		return invalidHandoff(path)
	}
	return nil
}

// exactField decodes the member of an object whose key matches name exactly.
// encoding/json folds key case when decoding into a struct, which Node's
// property lookup does not, so every field is read by its exact key.
func exactField(object map[string]json.RawMessage, name string, into any) bool {
	raw, present := object[name]
	return present && json.Unmarshal(raw, into) == nil
}

// jsonVersionIs reports whether raw is a JSON number equal to want, which is
// how the stored schema's `version !== N` check reads 1 and 1.0 alike.
func jsonVersionIs(object map[string]json.RawMessage, want float64) bool {
	var value float64
	return exactField(object, "version", &value) && value == want
}

// validateReplacementHandoff mirrors the stored schema: a version-2 object
// with a non-empty array of distinct, valid version-1 records. Keys match
// exactly and each member has the stored schema's own type.
func validateReplacementHandoff(data []byte, path string) ([]*pendingActionable, error) {
	var envelope map[string]json.RawMessage
	if err := json.Unmarshal(data, &envelope); err != nil {
		return nil, err
	}
	var entries []json.RawMessage
	if envelope == nil || !jsonVersionIs(envelope, 2) || !exactField(envelope, "pending", &entries) || len(entries) == 0 {
		return nil, invalidHandoff(path)
	}
	pending := make([]*pendingActionable, 0, len(entries))
	tokens := make(map[string]struct{}, len(entries))
	for _, entry := range entries {
		var fields map[string]json.RawMessage
		if err := json.Unmarshal(entry, &fields); err != nil || fields == nil || !jsonVersionIs(fields, 1) {
			return nil, invalidHandoff(path)
		}
		item := &pendingActionable{Version: 1}
		if !exactField(fields, "token", &item.Token) || !exactField(fields, "message", &item.Message) ||
			!exactField(fields, "predecessorArmPid", &item.PredecessorArmPid) {
			return nil, invalidHandoff(path)
		}
		if delivered, present := fields["delivered"]; present {
			if string(delivered) != "true" {
				return nil, invalidHandoff(path)
			}
			item.Delivered = true
		}
		if err := validatePendingActionable(item, path); err != nil {
			return nil, err
		}
		if _, duplicate := tokens[item.Token]; duplicate {
			return nil, invalidHandoff(path)
		}
		tokens[item.Token] = struct{}{}
		pending = append(pending, item)
	}
	return pending, nil
}

// replacementCoordinator carries actionable closes between two generations of
// one handoff path that share this process.
type replacementCoordinator struct {
	receiver      func(*pendingActionable)
	receiverOwner *watcher
	pending       []*pendingActionable
	nextToken     int
	nextGenID     int
	deliveries    map[string]*deliveryClaim
}

// deliveryClaim is one generation's in-flight delivery of a pending record,
// settled exactly once as "delivered" or "failed".
type deliveryClaim struct {
	owner  *watchGeneration
	once   sync.Once
	done   chan struct{}
	result string
}

func (c *deliveryClaim) settle(result string) {
	c.once.Do(func() {
		c.result = result
		close(c.done)
	})
}

func (c *deliveryClaim) wait() string {
	<-c.done
	return c.result
}

var (
	coordinatorMu sync.Mutex
	coordinators  = map[string]*replacementCoordinator{}
)

func coordinatorFor(handoff string) *replacementCoordinator {
	coordinatorMu.Lock()
	defer coordinatorMu.Unlock()
	if existing, ok := coordinators[handoff]; ok {
		return existing
	}
	created := &replacementCoordinator{deliveries: map[string]*deliveryClaim{}}
	coordinators[handoff] = created
	return created
}
