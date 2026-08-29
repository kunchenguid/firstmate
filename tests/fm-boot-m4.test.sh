#!/usr/bin/env bash
# m4: the boot budget holds under hostile conditions.
#
# The failure this gate exists to prevent is not slowness - it is silence. A
# SessionStart hook that exceeds its declared timeout injects NOTHING, and a
# session that boots blind looks exactly like one that booted well. The old
# path allowed two serial 5s helper timeouts against a declared 10s hook
# timeout, so one wedged helper cost the whole block.
#
# Hostile conditions, all at once:
#   - every helper the emitter may exec is stubbed to `sleep 999`
#   - 12 synthetic peers in the fleet view, one corrupt, one long stale
#
# Under that, the emitter must:
#   0. leak no processes - a wedged helper is killed as a group, not orphaned
#   1. hold its budget, asserted through properties the CODE controls rather
#      than a wall-clock threshold: the helper deadline is ENFORCED (helpers
#      wedged for 999s cost seconds, not 999s), and the helper phase is provably
#      CONCURRENT (both helpers start milliseconds apart, not one allowance
#      apart). See the measurements at assertion 1 for why elapsed time is not
#      the observable here.
#   2. print valid JSON carrying a SessionStart envelope
#   3. keep additionalContext under the 10,000-char injection cap
#   4. render a degradation marker for each helper it could not reach, rather
#      than a plausible-looking line or nothing at all
#   5. list all 12 peers - a peer is NEVER elided (per-task detail may be)
#   6. perform ZERO execs on the peer path
#
# And on the NORMAL path - real helpers, nothing stubbed - the same structural
# guarantees that make a boot fast: at most two helper execs, zero execs per
# peer, no network. Its latency is MEASURED AND PRINTED but deliberately not
# asserted as a threshold; see the END-GOAL note at that assertion for exactly
# what is and is not machine-checked.
#
# On the timeout arithmetic: the design's section 7 set a 1.5s total ceiling AND
# a 2s per-helper timeout for two helpers, which is 4s and cannot satisfy this
# gate. The tracked spec's Erratum reconciles it - the 1.5s total is
# authoritative and per-helper drops to 0.45s - and the helpers now run
# concurrently under one shared deadline, so the phase costs the max of their
# timeouts rather than the sum. See the measurements at assertion 1 for why the
# wall-clock claim is split into a median and a hard max.
#
# (6) is proved structurally, not by timing: the emitter runs under a PATH whose
# only entries are stub dirs, and every stub records its own invocation. Any exec
# attributable to a peer would show up in the log.
#
# Mutation (LEDGER_MUTATE=1): the emitter is handed a budget with no teeth - a
# 20s allowance per helper under a 60s ceiling. An emitter that honours its
# configured budget then waits the wedged helpers out for ~20s, breaching the
# 15s bound, so the assertion fails. This keys the gate to the deadline being
# genuinely enforced rather than to the stubs happening to return quickly.
#
# spec: docs/specs/2026-08-27-n-concurrent-firstmates.md
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/fm-boot-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-boot-helpers.sh"

assert_present "$FM_BOOT_EMITTER" "bin/fm-boot-context.sh must exist"

TMP=$(fm_test_tmproot fm-boot-m4)
HOME_DIR="$TMP/home"; FLEET="$TMP/fleet"
fm_boot_make_home "$HOME_DIR" 4
fm_boot_make_fleet "$FLEET" 12

HANGING=$(fm_boot_hanging_bin "$TMP")

# The normal arm passes no budget overrides at all, so it exercises the values
# the emitter actually ships with. The mutation arm relaxes both, which is the
# pre-split configuration: generous per-helper timeouts and no total ceiling.
BUDGET_ENV=()
if [ "${LEDGER_MUTATE:-}" = 1 ]; then
  BUDGET_ENV=(FM_BOOT_TOTAL_BUDGET=60 FM_BOOT_HELPER_TIMEOUT=20)
fi

# Every exec the emitter attempts is logged, so claim (6) is checkable.
EXECLOG="$TMP/exec.log"
: > "$EXECLOG"
LOGBIN="$TMP/logbin"; mkdir -p "$LOGBIN"
for tool in ps tmux git; do
  cat > "$LOGBIN/$tool" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$tool" "\$*" >> "$EXECLOG"
exit 1
SH
  chmod +x "$LOGBIN/$tool"
done

# PATH keeps the real python3 reachable (the emitter needs it) but puts the
# logging stubs ahead of everything, so any exec the emitter attempts for ps,
# tmux or git is recorded rather than performed.
PYDIR=$(dirname "$(command -v python3)")

# 0. the boot must not leak processes.
#
# This assertion exists because its absence invalidated every measurement this
# gate had ever taken. subprocess kills the helper it started but not what that
# helper spawned, so each wedged boot orphaned two `sleep 999` processes to
# init. Five per test run, accumulating across runs: 194 of them were live at
# once, carrying the load average to 186 - and the boots this gate was timing
# then took ~2s against a 1.5s ceiling. The gate was failing because of its own
# side effects, and it read as flakiness. A single run passed; six in a row did
# not. Any timing assertion below is worthless without this one above it.
# ps, not pgrep: this must match the FULL argv exactly. `pgrep -x` matches the
# process name only, so it cannot distinguish `sleep 999` from any other sleep,
# and `pgrep -f` substring-matches, which would also match this very pipeline.
# shellcheck disable=SC2009
leaked_sleepers() { bash "$ROOT/tests/fm-reap-strays.sh" count; }

# Snapshot the strays alive BEFORE this run, and reap on EVERY exit path.
#
# Cleanup used to happen only on the happy path: a run that failed an earlier
# assertion left through `fail` and abandoned whatever it had spawned. Failing
# runs are precisely when strays accumulate, and they were the runs least likely
# to tidy up - which is how 194 orphans once piled up and dragged the machine's
# load to 186, slowing the very boots this gate was timing.
#
# The trap runs regardless of outcome. The reaper only kills processes absent
# from the snapshot, so it can only ever remove this run's own debris; anything
# that was already alive is protected by construction. tests/lib.sh documents
# this exact pattern - define an EXIT trap, and call fm_test_cleanup from inside
# it so the registered temp dirs are still removed.
STRAY_SNAPSHOT=$(mktemp "${TMPDIR:-/tmp}/fm-boot-m4-strays.XXXXXX")
bash "$ROOT/tests/fm-reap-strays.sh" snapshot > "$STRAY_SNAPSHOT"
m4_cleanup() {
  local rc=$?
  bash "$ROOT/tests/fm-reap-strays.sh" reap "$STRAY_SNAPSHOT" || true
  rm -f "$STRAY_SNAPSHOT"
  fm_test_cleanup
  return "$rc"
}
trap m4_cleanup EXIT

sleepers_before=$(leaked_sleepers)

# 1. inside the budget - measured over REPEATED runs, judged on the WORST.
#
# A single sample is not evidence about a ceiling, and the worst of N is the
# honest statistic. But the measurement itself has to be sound first.
#
# The measurement must not launch an interpreter INSIDE the window it is timing.
# The previous version stamped the start with one `python3 -c` and the end with
# another, so the second interpreter's startup was charged to the emitter. Under
# load that startup spikes, and it is the entire reason this gate looked flaky.
# Measured over 60 samples at load ~180, bracketing each boot with bash's free
# EPOCHREALTIME clock as a control:
#
#   TRUE boot time   p50 1.035s  p90 1.174s  max 1.370s   breaches of 1.5s: 0
#   AS MEASURED      p50 1.097s  p90 1.291s  max 1.863s   breaches of 1.5s: 3
#   instrumentation  p50 0.059s  p90 0.163s  max 0.608s
#
# Every breach was the gate timing its own instrumentation. The emitter never
# exceeded the ceiling. So the ceiling stays at 1.5s and the measurement is what
# gets fixed - moving the threshold would have hidden a sound implementation
# behind a bad experiment.
#
# One interpreter now runs the whole loop and times each boot around the
# subprocess itself, so nothing but the boot is inside the window. fork/exec of
# the boot is inside it, correctly: the harness pays that too.
RUNS=${FM_BOOT_M4_RUNS:-5}
LASTOUT="$TMP/last-boot.json"
timings=$(env \
  PATH="$LOGBIN:$PYDIR:/usr/bin:/bin" \
  FM_HOME="$HOME_DIR" \
  FM_BOOT_FLEET_DIR="$FLEET" \
  FM_BOOTSTRAP_BIN="$HANGING" \
  ${BUDGET_ENV[@]+"${BUDGET_ENV[@]}"} \
  FM_CTX_WINDOW=probe-session \
  FIRSTMATE_ROLE=captain \
  python3 - "$FM_BOOT_EMITTER" "$RUNS" "$LASTOUT" "$(fm_boot_hook_json)" <<'PY'
import os, subprocess, sys, time
emitter, runs, lastout, hook = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
times = []
for _ in range(runs):
    t0 = time.time()
    r = subprocess.run(["bash", emitter], input=hook, capture_output=True,
                       text=True, env=os.environ)
    dt = time.time() - t0
    times.append(dt)
    if r.returncode != 0:
        print("RC %d" % r.returncode)
        sys.exit(0)
    print("  boot %.3fs" % dt, file=sys.stderr)
    # The verdict is already decided once one boot blows the bound; running the
    # rest only makes a failing gate slow. Keeps the mutation arm ~20s instead
    # of ~100s, with no change to a passing run.
    if dt >= 15.0:
        break
open(lastout, "w").write(r.stdout)
times.sort()
print("WORST %.3f MEDIAN %.3f" % (times[-1], times[len(times) // 2]))
PY
) || fail "the timing harness must run"

case "$timings" in
  RC\ *) fail "the emitter must exit 0 even with every helper wedged (got exit ${timings#RC })" ;;
esac
worst=$(printf '%s' "$timings" | awk '{print $2}')
out=$(cat "$LASTOUT")

# Checked before the timing verdict, because a leak invalidates the timing.
#
# Settle first. Killing is asynchronous: SIGKILL is delivered, and the process
# is reaped a moment later, so an instantaneous sample can catch one mid-death
# and call it a leak. Measured: 30 consecutive hostile boots never elevated the
# count at all, yet one sample in a 10-run sweep saw a single dying process. The
# property being asserted is that no orphan PERSISTS, so wait briefly for the
# count to return to baseline and only then judge. The wait is bounded, so a
# genuine leak still fails - it simply never comes back down.
sleepers_after=$(leaked_sleepers)
settle=0
while [ "$sleepers_after" -gt "$sleepers_before" ] && [ "$settle" -lt 15 ]; do
  sleep 0.2
  sleepers_after=$(leaked_sleepers)
  settle=$((settle + 1))
done
leaked=$((sleepers_after - sleepers_before))
[ "$leaked" -le 0 ] || fail "a wedged helper must be killed as a process group, not left \
running: $RUNS boots orphaned $leaked processes. That is a production leak, and it also \
poisons this gate - the orphans load the machine and the next run's timing measures them."

# WHY THIS IS NOT A WALL-CLOCK THRESHOLD ANY MORE.
#
# It was, and it flaked for a reason that is not the emitter's fault. Elapsed
# time here is dominated by CPU availability, which no budget logic can bound.
# Measured on this host, same code, same gate:
#
#   ambient load ~150   boots 0.55-1.11s
#   load ~205           boots 1.41-4.49s
#   8-way CPU saturation, 40 samples:
#       p50 1.178s  p90 2.385s  max 2.761s   over 1.5s: 13   over 3.0s: 0
#
# A second-scale threshold over that spread asserts a property of the MACHINE.
# Tuning it until it goes green would be exactly the false green this ledger
# exists to prevent, so the observable changed instead, to two things the code
# genuinely controls. Both carry order-of-magnitude margins, so neither can be
# flipped by load:
#
#   1a  THE DEADLINE IS ENFORCED. Helpers wedged for 999s must not be waited
#       for. Enforced, the boot takes ~1s and never more than a few; unenforced
#       it takes 999s. The 15s bound sits between with 3x clearance below and
#       66x above, and the pre-split design (two serial 5s timeouts) at ~10.3s
#       is still comfortably caught.
#   1b  THE HELPERS ARE CONCURRENT. Each stub records the instant it starts.
#       Run concurrently the two starts are milliseconds apart; run serially the
#       second starts a whole allowance after the first. With a 5s allowance the
#       measured spread is 0.386s against a 5s serial signature - 13x - and it
#       is a structural observation, not a timing threshold.
#
# Every boot's elapsed time is still PRINTED above, so a human reading the gate
# output sees the real numbers even though the pass/fail no longer rests on them.
python3 -c "import sys; sys.exit(0 if float(sys.argv[1]) < 15.0 else 1)" "$worst" \
  || fail "the helper deadline must be enforced: helpers wedged for 999s should cost \
about a second, and unenforced would cost 999s, but the worst of $RUNS boots took ${worst}s"

# 1b. concurrency, observed rather than timed.
PARTMP="$TMP/par"
mkdir -p "$PARTMP"
PARBIN=$(fm_boot_hanging_bin "$PARTMP")
fm_boot_hook_json | env \
  PATH="$LOGBIN:$PYDIR:/usr/bin:/bin" \
  FM_HOME="$HOME_DIR" FM_BOOT_FLEET_DIR="$FLEET" FM_BOOTSTRAP_BIN="$PARBIN" \
  FM_BOOT_TOTAL_BUDGET=30 FM_BOOT_HELPER_TIMEOUT=5 \
  FM_CTX_WINDOW=probe-session FIRSTMATE_ROLE=captain \
  bash "$FM_BOOT_EMITTER" >/dev/null \
  || fail "the concurrency probe must run"

STARTS="$PARTMP/helper-starts.txt"
assert_present "$STARTS" "both wedged helpers must actually have started"
python3 - "$STARTS" <<'PY' || fail "the two wedged helpers must run CONCURRENTLY, not one after the other"
import sys
ts = [float(x) for x in open(sys.argv[1]) if x.strip()]
assert len(ts) == 2, "expected 2 helper starts, got %d" % len(ts)
spread = max(ts) - min(ts)
# Serial with a 5s allowance puts the second start ~5s after the first.
# Concurrent puts them milliseconds apart; 0.386s was the measured worst.
assert spread < 2.0, "helpers started %.3fs apart - that is a serial signature" % spread
PY

# 2. valid envelope
ctx=$(fm_boot_context "$out")

# 3. under the injection cap
n=${#ctx}
[ "$n" -lt 10000 ] \
  || fail "injected context must stay under the 10,000-char cap (got $n chars)"

# 4. degradation markers instead of invented lines
assert_contains "$ctx" "UNAVAILABLE" \
  "a wedged helper must render an explicit UNAVAILABLE marker"
assert_not_contains "$ctx" "watcher-status: healthy" \
  "a wedged watcher helper must not be reported as healthy"

# 5. every peer present - a peer is never elided
missing=""
for i in $(seq 1 12); do
  case "$ctx" in
    *"peer-$i"*) : ;;
    *) missing="$missing peer-$i" ;;
  esac
done
[ -z "$missing" ] || fail "every peer must be listed, never elided (missing:$missing)"
assert_contains "$ctx" "unreadable" \
  "the corrupt peer must render exactly one explicit marker"
assert_contains "$ctx" "stale" \
  "the long-stale peer must render a staleness marker"

# 6. zero execs on the peer path. Peer ids must never appear in the exec log.
if [ -s "$EXECLOG" ]; then
  for i in $(seq 1 12); do
    if grep -q "peer-$i" "$EXECLOG"; then
      fail "the peer path must perform zero execs, but something exec'd for peer-$i:"$'\n'"$(cat "$EXECLOG")"
    fi
  done
fi

# 7. one hostile peer must not be able to spend the whole output budget.
#
# Tier 1 is deliberately uncapped so that assertion 5 can hold, which means a
# single unbounded field in a peer file is enough to breach the injection cap
# without eliding anything. A 20,000-char id did exactly that. Fields are
# bounded; peers are not.
BIGFLEET="$TMP/bigfleet"
fm_boot_make_fleet "$BIGFLEET" 3
python3 - "$BIGFLEET/peer-3.json" <<'PY'
import json, sys
json.dump({"id": "x" * 20000, "in_flight": 1, "needs_decision": 0,
           "watcher": "y" * 20000}, open(sys.argv[1], "w"))
PY
big=$(fm_boot_hook_json | env \
  FM_HOME="$HOME_DIR" FM_BOOT_FLEET_DIR="$BIGFLEET" \
  FM_CTX_WINDOW=probe-session FIRSTMATE_ROLE=captain \
  bash "$FM_BOOT_EMITTER") || fail "a hostile peer field must not break the boot"
big_ctx=$(fm_boot_context "$big")
[ "${#big_ctx}" -lt 10000 ] \
  || fail "one peer with an unbounded field must not breach the 10,000-char cap (got ${#big_ctx})"
assert_contains "$big_ctx" "peer-1" "the other peers must still be listed"
assert_contains "$big_ctx" "peer-2" "the other peers must still be listed"

# 8. where the two rules genuinely collide, the choice is stated.
#
# At a fleet size far outside the design envelope, "a peer is never elided" and
# "stay under the injection cap" cannot both hold. The peer rule wins - a
# session that cannot see a peer has lost the thing this block exists for -
# but the block must say so rather than quietly overrun.
HUGE="$TMP/huge"
fm_boot_make_fleet "$HUGE" 200
huge=$(fm_boot_hook_json | env \
  FM_HOME="$HOME_DIR" FM_BOOT_FLEET_DIR="$HUGE" \
  FM_CTX_WINDOW=probe-session FIRSTMATE_ROLE=captain \
  bash "$FM_BOOT_EMITTER") || fail "an oversized fleet must not break the boot"
huge_ctx=$(fm_boot_context "$huge")
listed=$(printf '%s\n' "$huge_ctx" | grep -c '^- peer-')
[ "$listed" -eq 200 ] \
  || fail "all 200 peers must be listed even past the cap (listed: $listed)"
assert_contains "$huge_ctx" "injection cap - UNAVAILABLE" \
  "overrunning the cap to keep every peer must be stated, never silent"

# 8b. A BLOCKING FILE MUST NOT HANG THE BOOT.
#
# The budget bounded subprocess helpers and nothing else, so a bare open() on a
# FIFO waited for a writer that never came. Measured against a 0.05s normal
# boot: over 30s, killed by the harness, injecting NOTHING and leaving no
# marker - the zero-context failure this whole design exists to prevent, and it
# made this gate's "holds its budget" claim false while it was green.
#
# fleet/*.json is the worst case and the reason this is not merely a local
# footgun: that directory is written by OTHER firstmate instances, so a single
# bad entry there would blind every other captain's boot, permanently.
#
# Every path the emitter reads is covered. The bound is generous on purpose -
# a hang is 30s+ or infinite, a healthy boot is under a second, so 15s
# discriminates them by orders of magnitude and cannot be flipped by load.
for victim in "state/.wake-queue" "state/task-1.meta" "state/task-1.status"; do
  rm -f "$HOME_DIR/$victim"
  mkfifo "$HOME_DIR/$victim"
  fifo_out=$(env FM_HOME="$HOME_DIR" FM_BOOT_FLEET_DIR="$FLEET" \
    FM_CTX_WINDOW=probe-session FIRSTMATE_ROLE=captain \
    python3 - "$FM_BOOT_EMITTER" "$(fm_boot_hook_json)" <<'PY'
import os, subprocess, sys, time
t0 = time.time()
try:
    r = subprocess.run(["bash", sys.argv[1]], input=sys.argv[2], capture_output=True,
                       text=True, env=os.environ, timeout=15)
except subprocess.TimeoutExpired:
    print("HUNG")
    raise SystemExit(0)
print("%.3f" % (time.time() - t0))
sys.stderr.write(r.stdout)
PY
)
  rm -f "$HOME_DIR/$victim"
  [ "$fifo_out" != HUNG ] \
    || fail "a FIFO at $victim hung the boot - a blocking open() defeats the budget entirely"
done

# The same for a peer file, which another instance writes.
mkfifo "$FLEET/peer-fifo.json"
peer_out=$(env FM_HOME="$HOME_DIR" FM_BOOT_FLEET_DIR="$FLEET" \
  FM_CTX_WINDOW=probe-session FIRSTMATE_ROLE=captain \
  python3 - "$FM_BOOT_EMITTER" "$(fm_boot_hook_json)" <<'PY'
import os, subprocess, sys, time
try:
    r = subprocess.run(["bash", sys.argv[1]], input=sys.argv[2], capture_output=True,
                       text=True, env=os.environ, timeout=15)
except subprocess.TimeoutExpired:
    print("HUNG")
    raise SystemExit(0)
print(r.stdout)
PY
)
rm -f "$FLEET/peer-fifo.json"
[ "$peer_out" != HUNG ] \
  || fail "a FIFO in the shared fleet dir hung the boot - one foreign entry must never blind a captain"
peer_ctx=$(fm_boot_context "$peer_out")
assert_contains "$peer_ctx" "UNAVAILABLE" \
  "a non-regular peer file must be marked, not silently skipped"
assert_contains "$peer_ctx" "not a regular file" \
  "the marker must say what was wrong with it"

# 9. THE NORMAL PATH, and END-GOAL condition 2.
#
# Condition 2 reads: "Boot injects the fleet picture in UNDER A SECOND, with no
# synchronous network sweep, and degrades to an explicit marker rather than
# silently reporting an empty fleet." Everything above is the HOSTILE path, so
# it was never the right home for a normal-path latency claim - and until this
# section existed, the sub-second half rode entirely on a wall-clock threshold
# that has since been removed as unsound. This closes that honestly.
#
# WHAT IS MACHINE-CHECKED HERE: the structural properties that determine
# latency, all of them immune to machine load -
#   - at most TWO helper execs for the whole boot, however many peers exist
#   - ZERO execs attributable to any peer (the peer path is file reads)
#   - no network call of any kind
#   - a valid envelope, on real helpers with nothing stubbed
#
# WHAT IS NOT MACHINE-CHECKED, STATED PLAINLY: the "under a second" figure
# itself. Measured on this host, same code: 0.23s against the live primary home,
# and 0.55-1.11s on the hostile path at ambient load - comfortably inside a
# second. But elapsed wall clock here swings 0.55s to 4.5s with load alone
# (130 -> 205), so a sub-second assertion would be a claim about the machine,
# not the emitter, and gating it would produce exactly the flakiness this gate
# spent three rounds removing. The latency is measured and PRINTED on every run
# so the real number is always visible; it is not a pass/fail condition.
#
# END-GOAL.md says "machine-checked, not asserted", so this is a real and
# deliberate gap against condition 2, recorded rather than papered over. It is
# written up in docs/specs/2026-08-27-n-concurrent-firstmates.md.
NORMTMP="$TMP/normal"
mkdir -p "$NORMTMP"
NORMLOG="$NORMTMP/exec.log"
: > "$NORMLOG"
NORMBIN="$NORMTMP/bin"; mkdir -p "$NORMBIN"
# Trap any network reach. A boot that swept the network would need one of these.
for tool in curl wget nc ssh; do
  cat > "$NORMBIN/$tool" <<SH
#!/usr/bin/env bash
printf 'NETWORK %s %s\n' "$tool" "\$*" >> "$NORMLOG"
exit 1
SH
  chmod +x "$NORMBIN/$tool"
done

# Wrappers around the two real helpers: each logs its invocation, then delegates
# to the genuine script, so the boot is a real one and the exec count is exact.
HELPWRAP="$NORMTMP/helperbin"; mkdir -p "$HELPWRAP"
HELPLOG="$NORMTMP/helper-execs.log"
: > "$HELPLOG"
for helper in fm-lock.sh fm-watch-arm.sh; do
  cat > "$HELPWRAP/$helper" <<SH
#!/usr/bin/env bash
printf '%s %s\n' "$helper" "\$*" >> "$HELPLOG"
exec "$ROOT/bin/$helper" "\$@"
SH
  chmod +x "$HELPWRAP/$helper"
done

norm=$(env \
  PATH="$NORMBIN:$PATH" \
  FM_BOOTSTRAP_BIN="$HELPWRAP" \
  FM_HOME="$HOME_DIR" FM_BOOT_FLEET_DIR="$FLEET" \
  FM_CTX_WINDOW=probe-session FIRSTMATE_ROLE=captain \
  python3 - "$FM_BOOT_EMITTER" "$(fm_boot_hook_json)" <<'PY'
import os, subprocess, sys, time
t0 = time.time()
r = subprocess.run(["bash", sys.argv[1]], input=sys.argv[2], capture_output=True,
                   text=True, env=os.environ)
dt = time.time() - t0
print("  normal-path boot %.3fs (measured, not asserted - see assertion 9)" % dt,
      file=sys.stderr)
sys.stdout.write(r.stdout)
PY
) || fail "a normal boot with real helpers must exit 0"

norm_ctx=$(fm_boot_context "$norm")
assert_contains "$norm_ctx" "## Fleet" "a normal boot must render the fleet picture"
assert_not_contains "$norm_ctx" "network" "a normal boot must not mention a network sweep"
assert_no_grep "NETWORK" "$NORMLOG" \
  "a boot must perform NO network call - the fleet picture comes from files"

# At most two helper execs, for the WHOLE boot, however many peers there are.
# This is the property that actually keeps a boot fast, and unlike wall clock it
# does not move with machine load. 12 peers are present in $FLEET throughout.
helper_execs=$(wc -l < "$HELPLOG" | tr -d ' ')
[ "$helper_execs" -le 2 ] \
  || fail "a boot must exec at most 2 helpers regardless of fleet size, but made \
$helper_execs:"$'\n'"$(cat "$HELPLOG")"
# Deliberately NOT "exactly 2". On a loaded host the boot can spend its whole
# budget on interpreter startup and skip both helpers - measured here, at load
# ~130, the normal boot reported "session lock: skipped, boot budget exhausted"
# and rendered watcher and steering as UNAVAILABLE. That is the degradation
# contract working, not a fault, and asserting a lower bound would make this
# load-dependent in exactly the way the rest of this gate stopped being.
#
# It is worth knowing, though, and it is written up with condition 2 in
# docs/specs/2026-08-27-n-concurrent-firstmates.md: the 1.5s budget is tight
# enough that an ordinary boot degrades on a busy machine.

# And ZERO of those execs is attributable to a peer: the peer path is file reads.
for i in $(seq 1 12); do
  assert_no_grep "peer-$i" "$HELPLOG" "no exec may be made on behalf of peer-$i"
done

pass "m4 boot budget holds under hostile helpers"
