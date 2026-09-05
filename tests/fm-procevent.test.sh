#!/usr/bin/env bash
# Behavior tests for the generic process-to-event runner and its Lavish adapter.
#
# The source under test is a fake blocking process that returns only when its
# trigger file appears, so completion is a real process event and no test here
# depends on a discovery timer. The Lavish adapter is exercised through its own
# public commands against the currently published poll shape; no live Lavish
# server is started.
#
# Delivery is deliberately NOT asserted as at-least-once or lossless: the
# published Lavish poll clears feedback destructively before returning it, so
# the only durability under test is the runner's own - output that reached the
# runner is stored before it is announced.
set -u
umask 077

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

BLOCKER="$TMP_ROOT/blocker.sh"
cat > "$BLOCKER" <<'SH'
#!/usr/bin/env bash
# Blocks until the trigger exists, then emits its payload. Completion is the
# event; nothing here polls on a schedule.
trigger=$1; shift
while [ ! -e "$trigger" ]; do sleep 0.05; done
[ -n "${BLOCKER_STDERR:-}" ] && printf 'noise on stderr\n' >&2
[ -n "${BLOCKER_EXIT:-}" ] && exit "$BLOCKER_EXIT"
printf '%s\n' "$@"
SH
chmod +x "$BLOCKER"

pe() { FM_HOME="$1" "$ROOT/bin/fm-procevent.sh" "${@:2}"; }

# Every source this suite registers is tracked so teardown can stop its runner.
# A runner started by reconcile is detached and reparented, so a source that
# never completes outlives the suite unless it is retired explicitly - removing
# the fixture directory does not stop an already-running child.
PE_TRACKED=()
pe_register() {  # <home> <adapter> <source-id> -- <argv>...
  local home=$1 adapter=$2 id=$3
  shift 3
  PE_TRACKED+=("$home|$id")
  pe "$home" register "$adapter" "$id" "$@"
}

procevent_teardown() {
  local entry home seen=$'\n'
  for entry in ${PE_TRACKED[@]+"${PE_TRACKED[@]}"}; do
    home=${entry%%|*}
    case "$seen" in
      *$'\n'"$home"$'\n'*) continue ;;
    esac
    seen+="$home"$'\n'
    FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
  done
  fm_test_cleanup
}
trap procevent_teardown EXIT
new_home() { mkdir -p "$1/state"; }
wake_payloads() { awk -F '\t' '{print $5}' "$1/state/.wake-queue" 2>/dev/null; }

first_result() {  # <home> <source-id>: print the first captured result, if any
  local g
  for g in "$1/state/procevent-inbox/$2".*.result; do
    [ -e "$g" ] || continue
    printf '%s\n' "$g"
    return 0
  done
  return 1
}

count_results() {  # <home> <source-id>
  local g n=0
  for g in "$1/state/procevent-inbox/$2".*.result; do
    [ -e "$g" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

wait_for() {  # <file> [tries]
  local f=$1 n=${2:-100}
  for _ in $(seq 1 "$n"); do [ -s "$f" ] && return 0; sleep 0.1; done
  return 1
}

# <file> <count> [tries]: wait until <file> holds at least <count> lines. A
# detached runner appends its execution marker after the command that started it
# has already returned, so a caller that needs that append must wait for it
# rather than assume a fixed settle window covered it on a loaded machine.
wait_for_lines() {
  local f=$1 want=$2 n=${3:-100} have
  for _ in $(seq 1 "$n"); do
    have=$(wc -l < "$f" 2>/dev/null | tr -d ' ')
    case "$have" in ''|*[!0-9]*) have=0 ;; esac
    [ "$have" -ge "$want" ] && return 0
    sleep 0.1
  done
  return 1
}

hold_source_lock() {  # <source-id> <ready-file> <release-file>
  local id=$1 ready=$2 release=$3 parent=$$
  FM_HOME="$TMP_ROOT/lock-helper-home" bash -c '
    . "$1/bin/fm-pr-lib.sh"
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-procevent-lib.sh"
    fm_procevent_source_lock_acquire "$2" || exit 1
    trap "fm_procevent_source_lock_release \"$2\"" EXIT
    printf "ready\n" > "$3"
    while [ ! -e "$4" ]; do
      kill -0 "$5" 2>/dev/null || exit 0
      sleep 0.02
    done
  ' _ "$ROOT" "$id" "$ready" "$release" "$parent" &
  HOLDER_PID=$!
}

hold_source_lock_then_handle() {  # <home> <source-id> <sequence> <ready-file> <release-file>
  local home=$1 id=$2 seq=$3 ready=$4 release=$5 parent=$$
  FM_HOME="$home" bash -c '
    . "$1/bin/fm-pr-lib.sh"
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-procevent-lib.sh"
    fm_procevent_source_lock_acquire "$2" || exit 1
    trap "fm_procevent_source_lock_release \"$2\"" EXIT
    printf "ready\n" > "$4"
    while [ ! -e "$5" ]; do
      kill -0 "$6" 2>/dev/null || exit 1
      sleep 0.02
    done
    fm_procevent_mark_handled "$3/state" "$2" "$7"
  ' _ "$ROOT" "$id" "$home" "$ready" "$release" "$parent" "$seq" &
  HOLDER_PID=$!
}

# --- inert with nothing configured ------------------------------------------
IDLE="$TMP_ROOT/idle"; mkdir -p "$IDLE"
out=$(pe "$IDLE" list)
assert_contains "$out" "no sources registered" "an unconfigured home reports no sources"
out=$(pe "$IDLE" reconcile)
assert_contains "$out" "published=0 started=0" "reconcile is a no-op with nothing registered"
[ -z "$(ls -A "$IDLE/state" 2>/dev/null)" ] || fail "an unconfigured home generated state: $(ls -A "$IDLE/state")"
pass "no configured source means no generated state and no process"

sup=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2" && echo yes || echo no' _ "$ROOT" "$IDLE/state")
assert_contains "$sup" no "an unconfigured home does not need supervision"

# --- a blocking source completes into exactly one normalized event ----------
H1="$TMP_ROOT/h1"; mkdir -p "$H1"
TRIG="$TMP_ROOT/trigger-one"
out=$(pe_register "$H1" lavish src-one -- "$BLOCKER" "$TRIG" "payload one")
assert_contains "$out" "registered: src-one" "register records a source"

sup=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2" && echo yes || echo no' _ "$ROOT" "$H1/state")
assert_contains "$sup" yes "a registered source needs supervision with no task metadata"

pe "$H1" reconcile >/dev/null
# Reconcile's replacement runner is detached, so ownership is recorded after
# reconcile has already returned. Wait for the claim itself: a duplicate start
# only has an owner to lose to once that claim exists.
wait_for "$FM_PROCEVENT_CLAIM_ROOT/src-one.claim" || fail "reconcile never claimed the registered source"
out=$(pe "$H1" start src-one)
assert_contains "$out" "already owned" "a duplicate start loses instead of running a second child"

: > "$TRIG"
wait_for "$H1/state/.wake-queue" || fail "no event was published after the source completed"
payload=$(wake_payloads "$H1")
assert_contains "$payload" "procevent lavish src-one 1" "completion publishes the committed result sequence"
assert_not_contains "$payload" "payload one" "source output never reaches the event line"
[ "$(printf '%s\n' "$payload" | grep -c .)" = 1 ] || fail "expected exactly one event, got: $payload"
pass "one blocking completion yields exactly one bounded normalized event"

RESULT=$(first_result "$H1" src-one || true)
[ -n "$RESULT" ] || fail "no durable result was captured"
mode=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_mode "$2"' _ "$ROOT" "$RESULT")
assert_contains "$mode" 600 "the captured result is private"
assert_grep 'payload one' "$RESULT" "the captured result holds the source output verbatim"
assert_grep 'lavish' "${RESULT%.result}.adapter" "the captured result retains its immutable adapter"
assert_absent "${RESULT%.result}.handled" "publication alone never marks a result handled"

# --- a home spelled through a symlinked ancestor still runs its sources ------
# Such a home must run process-event sources exactly like a physically spelled
# one: reconcile's detached runner discards its own stderr, so a refusal here is
# invisible to the caller and the source simply never fires.
HPHYS="$TMP_ROOT/symlinked-parent-target"
mkdir -p "$HPHYS"
ln -s "$HPHYS" "$TMP_ROOT/symlinked-parent"
HSYM="$TMP_ROOT/symlinked-parent/home"; new_home "$HSYM"
SYM_TRIGGER="$TMP_ROOT/symlink-trigger"
pe_register "$HSYM" lavish symlinked-src -- "$BLOCKER" "$SYM_TRIGGER" "symlinked payload" >/dev/null
pe "$HSYM" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/symlinked-src.claim" \
  || fail "a home reached through a symlinked ancestor never claimed its source"
: > "$SYM_TRIGGER"
wait_for "$HSYM/state/.wake-queue" \
  || fail "a home reached through a symlinked ancestor published no event"
assert_contains "$(wake_payloads "$HSYM")" "procevent lavish symlinked-src 1" \
  "the symlinked-ancestor home publishes the committed result sequence"
SYM_RESULT=$(first_result "$HSYM" symlinked-src || true)
[ -n "$SYM_RESULT" ] || fail "the symlinked-ancestor home captured no durable result"
assert_grep 'symlinked payload' "$SYM_RESULT" \
  "the symlinked-ancestor home captures the source output verbatim"
pass "a home reached through a symlinked ancestor runs its sources normally"

# --- the public start boundary establishes generation group ownership -------
HPG="$TMP_ROOT/hpg"; new_home "$HPG"
DIRECT_TRIGGER="$TMP_ROOT/direct-trigger"
pe_register "$HPG" lavish direct-src -- "$BLOCKER" "$DIRECT_TRIGGER" "direct result" >/dev/null
pe "$HPG" start direct-src > "$TMP_ROOT/direct-start.out" &
direct_runner=$!
wait_for "$FM_PROCEVENT_CLAIM_ROOT/direct-src.claim" || fail "direct start never claimed its source"
direct_leader=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/direct-src.claim")
direct_group=$(ps -o pgid= -p "$direct_leader" 2>/dev/null | tr -d '[:space:]')
[ "$direct_group" = "$direct_leader" ] \
  || fail "direct start claimed before leading its process group: pid=$direct_leader pgid=$direct_group"
: > "$DIRECT_TRIGGER"
wait "$direct_runner" || fail "direct start failed after its source completed"
assert_contains "$(cat "$TMP_ROOT/direct-start.out")" "captured:" "direct start captures its result"
pass "public start owns the process group recorded by its claim"

SHARED_TRIGGER="$TMP_ROOT/shared-trigger"
SHARED_SIBLING="$TMP_ROOT/shared-sibling"
SHARED_LAUNCHER="$TMP_ROOT/shared-launcher.pl"
cat > "$SHARED_LAUNCHER" <<'PL'
use strict;
use warnings;
my ($sibling_file, @command) = @ARGV;
pipe(my $reader, my $writer) or exit 125;
defined(my $runner = fork) or exit 125;
if ($runner == 0) {
  close $reader;
  setpgrp(0, 0) or exit 125;
  print {$writer} "ready\n";
  close $writer;
  exec @command;
  exit 125;
}
close $writer;
<$reader>;
close $reader;
defined(my $sibling = fork) or exit 125;
if ($sibling == 0) {
  setpgrp(0, $runner) or exit 125;
  open(my $out, '>', $sibling_file) or exit 125;
  print {$out} "$$\n";
  close $out;
  sleep 30;
  exit 0;
}
waitpid($runner, 0);
waitpid($sibling, 0);
exit 0;
PL
pe_register "$HPG" lavish shared-src -- "$BLOCKER" "$SHARED_TRIGGER" "shared result" >/dev/null
FM_HOME="$HPG" perl "$SHARED_LAUNCHER" "$SHARED_SIBLING" \
  "$ROOT/bin/fm-procevent.sh" start shared-src > "$TMP_ROOT/shared-start.out" &
shared_launcher=$!
wait_for "$SHARED_SIBLING" || fail "shared caller group never started its unrelated sibling"
wait_for "$FM_PROCEVENT_CLAIM_ROOT/shared-src.claim" || fail "shared-group start never claimed its source"
shared_sibling=$(cat "$SHARED_SIBLING")
pe "$HPG" retire shared-src >/dev/null
kill -0 "$shared_sibling" 2>/dev/null || fail "retirement signaled an unrelated caller-group process"
kill "$shared_sibling" 2>/dev/null || true
wait "$shared_launcher" || fail "shared caller-group fixture did not exit cleanly"
pass "public start never claims an inherited caller process group"

# --- an unhandled result remains eligible for re-announcement on restart ----
# A result is durable but nothing has ever acknowledged handling it. Every
# reconcile call - not just the first restart after a crash - must keep
# re-announcing it, because the only thing that stops re-announcement is an
# explicit handled acknowledgement, never a prior publication.
H2="$TMP_ROOT/h2"; new_home "$H2"
future_status=0
future_out=$(pe "$H2" handled src-cut 7 2>&1) || future_status=$?
[ "$future_status" -ne 0 ] || fail "handled accepted a generation that has not been captured"
assert_contains "$future_out" "cannot durably record handling" "premature acknowledgement is rejected through the public interface"
assert_absent "$H2/state/procevent-inbox/src-cut.7.handled" "premature acknowledgement creates no marker for the future generation"
mkdir -p "$H2/state/procevent-inbox"
printf 'stranded result\n' > "$H2/state/procevent-inbox/src-cut.7.result"
printf 'lavish\n' > "$H2/state/procevent-inbox/src-cut.7.adapter"
chmod 0600 "$H2/state/procevent-inbox/src-cut.7.result" "$H2/state/procevent-inbox/src-cut.7.adapter"
out=$(pe "$H2" reconcile)
assert_contains "$out" "published=1" "a durably captured but unhandled result is announced after restart"
assert_contains "$(wake_payloads "$H2")" "procevent lavish src-cut 7" "durable adapter identity survives without a registration"
assert_absent "$H2/state/procevent-inbox/src-cut.7.handled" "recovery alone never marks the recovered result handled"
mv "$H2/state/.wake-queue" "$H2/state/.wake-queue.drained-1"
out=$(pe "$H2" reconcile)
assert_contains "$out" "published=1" "an unhandled result is re-announced on every reconcile, not only the first"
assert_contains "$(wake_payloads "$H2")" "procevent lavish src-cut 7" "the repeat wake preserves its deduplication identity"
[ "$(count_results "$H2" src-cut)" = 1 ] || fail "repeat re-announcement created a second durable copy"
mv "$H2/state/.wake-queue" "$H2/state/.wake-queue.drained-2"

ack_out=$(pe "$H2" handled src-cut 7)
assert_contains "$ack_out" "handled: src-cut 7" "the owned handling interface newly authorizes the first acknowledgement"
assert_present "$H2/state/procevent-inbox/src-cut.7.handled" "acknowledgement durably records handling"
before=$(wake_payloads "$H2" | wc -l | tr -d ' ')
out=$(pe "$H2" reconcile)
assert_contains "$out" "published=0" "reconcile stops re-announcing once a result is durably handled"
[ "$(wake_payloads "$H2" | wc -l | tr -d ' ')" = "$before" ] || fail "a handled result was announced again"

repeat_out=$(pe "$H2" handled src-cut 7)
assert_contains "$repeat_out" "already-handled: src-cut 7" "repeated acknowledgement is safe and reports the repeat distinctly"
case "$repeat_out" in
  handled:*) fail "a repeat acknowledgement re-authorized a second handled effect: $repeat_out" ;;
esac
pass "an unhandled result survives restart and repeat drains, and only explicit acknowledgement stops its re-announcement"

HRACE="$TMP_ROOT/hrace"; new_home "$HRACE"
mkdir -p "$HRACE/state/procevent-inbox"
printf 'racing result\n' > "$HRACE/state/procevent-inbox/racing-src.1.result"
printf 'lavish\n' > "$HRACE/state/procevent-inbox/racing-src.1.adapter"
chmod 0600 "$HRACE/state/procevent-inbox/racing-src.1.result" "$HRACE/state/procevent-inbox/racing-src.1.adapter"
RACE_PUBLISH_READY="$TMP_ROOT/race-publish-ready"
RACE_PUBLISH_RELEASE="$TMP_ROOT/race-publish-release"
RACE_RECONCILE_OUT="$TMP_ROOT/race-reconcile.out"
hold_source_lock_then_handle "$HRACE" racing-src 1 "$RACE_PUBLISH_READY" "$RACE_PUBLISH_RELEASE"
RACE_HANDLE_PID=$HOLDER_PID
wait_for "$RACE_PUBLISH_READY" || fail "publication race barrier did not acquire the source lock"
pe "$HRACE" reconcile > "$RACE_RECONCILE_OUT" &
RACE_RECONCILE_PID=$!
sleep 0.3
assert_absent "$HRACE/state/.wake-queue" "publication bypassed the source serialization boundary"
: > "$RACE_PUBLISH_RELEASE"
wait "$RACE_HANDLE_PID" || fail "publication race barrier could not record handling"
wait "$RACE_RECONCILE_PID" || fail "reconcile failed after the concurrent acknowledgement"
assert_contains "$(cat "$RACE_RECONCILE_OUT")" "published=0" "reconcile rechecks handling at the serialized publication boundary"
assert_present "$HRACE/state/procevent-inbox/racing-src.1.handled" "the concurrent acknowledgement remains durable"
assert_absent "$HRACE/state/.wake-queue" "an acknowledged result was appended after handling completed"
pass "publication cannot race a handled acknowledgement"

HPRIVATE="$TMP_ROOT/hprivate"; new_home "$HPRIVATE"
mkdir -p "$HPRIVATE/state/procevent-inbox"
printf 'private result\n' > "$HPRIVATE/state/procevent-inbox/private-src.1.result"
printf 'lavish\n' > "$HPRIVATE/state/procevent-inbox/private-src.1.adapter"
chmod 0600 "$HPRIVATE/state/procevent-inbox/private-src.1.result" "$HPRIVATE/state/procevent-inbox/private-src.1.adapter"
FAIL_CHMOD_BIN="$TMP_ROOT/fail-chmod-bin"
mkdir -p "$FAIL_CHMOD_BIN"
cat > "$FAIL_CHMOD_BIN/chmod" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$FAIL_CHMOD_BIN/chmod"
private_status=0
private_out=$(PATH="$FAIL_CHMOD_BIN:$PATH" pe "$HPRIVATE" handled private-src 1 2>&1) || private_status=$?
[ "$private_status" -ne 0 ] || fail "handled succeeded when private mode enforcement failed"
assert_contains "$private_out" "cannot durably record handling" "mode enforcement failure is reported through the owned interface"
assert_absent "$HPRIVATE/state/procevent-inbox/private-src.1.handled" "failed mode enforcement left an authoritative marker"
private_out=$(umask 000; pe "$HPRIVATE" handled private-src 1)
assert_contains "$private_out" "handled: private-src 1" "handling succeeds after private mode enforcement recovers"
private_mode=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_mode "$2"' _ "$ROOT" "$HPRIVATE/state/procevent-inbox/private-src.1.handled")
assert_contains "$private_mode" 600 "the handled marker is private under a permissive caller umask"
pass "handled acknowledgement creation is private and fails safely"

# --- a terminal result retires its source, on the adapter's verdict alone ----
# The runner must carry no notion of its own about what "done" means for a
# source. It asks that source's adapter whether the captured result ends the
# source, and retires the registration only on that adapter's verdict. Two
# fixture adapters isolate exactly that decision - one that ends on any result,
# one with no terminal knowledge at all - so the observed behavior is proven to
# follow the adapter rather than any condition built into the runner.
ADAPTER_ROOT="$TMP_ROOT/adapter-root"
mkdir -p "$ADAPTER_ROOT/bin"
cat > "$ADAPTER_ROOT/bin/fm-procevent-endnow.sh" <<'SH'
#!/usr/bin/env bash
# Fixture adapter: every captured result ends this source.
case "${1-}" in
  terminal) [ -f "${2-}" ] && exit 0 || exit 1 ;;
esac
exit 2
SH
cat > "$ADAPTER_ROOT/bin/fm-procevent-openended.sh" <<'SH'
#!/usr/bin/env bash
# Fixture adapter with no terminal knowledge at all: nothing ever ends it.
exit 2
SH
cat > "$ADAPTER_ROOT/bin/fm-procevent-applying.sh" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  autohandle)
    printf '%s %s\n' "$2" "$3" >> "$FM_HOME/state/applied"
    "$FM_PROCEVENT_UNDER_TEST" handled "$2" "$3" >/dev/null
    ;;
  *) exit 2 ;;
esac
SH
cat > "$ADAPTER_ROOT/bin/fm-procevent-selfann.sh" <<'SH'
#!/usr/bin/env bash
# Fixture adapter that declares a durable downstream announcement of its own.
# FM_HOME/state/selfann-fail makes its application fail so the fallback
# publication path stays provable.
case "${1-}" in
  self-announcing) exit 0 ;;
  autohandle)
    [ ! -e "$FM_HOME/state/selfann-fail" ] || exit 1
    printf '%s %s\n' "$2" "$3" >> "$FM_HOME/state/applied"
    "$FM_PROCEVENT_UNDER_TEST" handled "$2" "$3" >/dev/null
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$ADAPTER_ROOT/bin/fm-procevent-endnow.sh" "$ADAPTER_ROOT/bin/fm-procevent-openended.sh" \
  "$ADAPTER_ROOT/bin/fm-procevent-applying.sh" "$ADAPTER_ROOT/bin/fm-procevent-selfann.sh"

pe_adapter() {  # <home> <command>...: run the runner against the fixture adapters
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$ADAPTER_ROOT" FM_PROCEVENT_UNDER_TEST="$ROOT/bin/fm-procevent.sh" \
    FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" "$@"
}

HPUBLISH="$TMP_ROOT/hpublish"; new_home "$HPUBLISH"
PE_TRACKED+=("$HPUBLISH|publish-src")
pe_adapter "$HPUBLISH" register applying publish-src -- /bin/echo "apply after publish" >/dev/null
mkdir "$HPUBLISH/state/.wake-queue"
out=$(pe_adapter "$HPUBLISH" start publish-src 2>&1)
assert_contains "$out" "not-autohandled: publish-src" "failed publication did not suppress automatic application"
assert_absent "$HPUBLISH/state/applied" "a result was applied before its wake was durably published"
assert_absent "$HPUBLISH/state/procevent-inbox/publish-src.1.handled" "a result was acknowledged before its wake was durably published"
rmdir "$HPUBLISH/state/.wake-queue"
# This source's child returns instantly, so leaving it registered would have the
# recovery reconcile below start a detached poll that races every assertion after
# it for the source claim, the next sequence, and this home's applied record.
# Re-announcement is proven from the durable inbox alone and needs no
# registration, so retire it first - the same retire-before-reconcile discipline
# the blocker-backed sources rely on - and prove no competing poll was started.
pe_adapter "$HPUBLISH" retire publish-src >/dev/null
out=$(pe_adapter "$HPUBLISH" reconcile)
assert_contains "$out" "published=1" "the unpublished capture was not announced on later reconciliation"
assert_contains "$out" "started=0" "reconcile started an always-ready poll that races the recovery assertions"
assert_contains "$(wake_payloads "$HPUBLISH")" "procevent applying publish-src 1" "later reconciliation did not deliver the capture to a handler"
FM_HOME="$HPUBLISH" FM_PROCEVENT_UNDER_TEST="$ROOT/bin/fm-procevent.sh" \
  "$ADAPTER_ROOT/bin/fm-procevent-applying.sh" autohandle publish-src 1 \
    "$HPUBLISH/state/procevent-inbox/publish-src.1.result"
assert_grep 'publish-src 1' "$HPUBLISH/state/applied" "the handler could not apply the later announcement"
assert_present "$HPUBLISH/state/procevent-inbox/publish-src.1.handled" "the later handler application was not acknowledged"
pass "automatic application waits for durable publication and failed publication remains recoverable"

# A self-announcing adapter inverts that order on its own declaration: the
# runner applies first and publishes nothing for a capture the adapter fully
# applied and acknowledged, because the adapter's own durable downstream
# channel is the announcement. The declaration never silences a capture the
# adapter could NOT apply - that one still publishes for the handler.
HSELF="$TMP_ROOT/hself"; new_home "$HSELF"
PE_TRACKED+=("$HSELF|self-src")
pe_adapter "$HSELF" register selfann self-src -- /bin/echo "self announced" >/dev/null
out=$(pe_adapter "$HSELF" start self-src 2>&1)
assert_contains "$out" "autohandled: self-src" "the self-announcing adapter did not apply its own capture"
assert_not_contains "$out" "not-autohandled" "the applied capture was still reported as left for the handler"
assert_grep 'self-src 1' "$HSELF/state/applied" "the self-announcing capture was not applied"
assert_present "$HSELF/state/procevent-inbox/self-src.1.handled" "the self-announcing application was not acknowledged"
if [ -e "$HSELF/state/.wake-queue" ] && grep -q 'procevent selfann self-src 1' "$HSELF/state/.wake-queue"; then
  fail "a fully autohandled self-announcing capture still published a duplicate check wake"
fi
# This self-announcing source's child returns instantly, so reconcile would
# restart it and that detached poll would race the failing-path start below for
# the source claim - non-deterministically stealing its sequence or the claim
# itself. Retire it before the re-announcement check so reconcile starts no
# competing poll, then re-register for the failing-path capture, the same
# retire-before-reconcile discipline the blocker-backed sources rely on.
pe_adapter "$HSELF" retire self-src >/dev/null
out=$(pe_adapter "$HSELF" reconcile)
assert_contains "$out" "published=0" "reconcile re-announced a capture its adapter already acknowledged"
assert_contains "$out" "started=0" "reconcile restarted an always-ready acknowledged source and raced the next start"
pe_adapter "$HSELF" register selfann self-src -- /bin/echo "self announced" >/dev/null
: > "$HSELF/state/selfann-fail"
out=$(pe_adapter "$HSELF" start self-src 2>&1)
assert_contains "$out" "not-autohandled: self-src" "a failed self-announcing application was reported as applied"
assert_absent "$HSELF/state/procevent-inbox/self-src.2.handled" "a failed self-announcing application was acknowledged anyway"
assert_contains "$(wake_payloads "$HSELF")" "procevent selfann self-src 2" \
  "a capture the self-announcing adapter could not apply lost its check-wake announcement"
rm -f "$HSELF/state/selfann-fail"
pass "a self-announcing adapter applies quietly and still publishes what it could not apply"

HTERM="$TMP_ROOT/hterm"; new_home "$HTERM"
PE_TRACKED+=("$HTERM|ends-src")
pe_adapter "$HTERM" register endnow ends-src -- /bin/echo "terminal payload" >/dev/null
out=$(pe_adapter "$HTERM" start ends-src)
assert_contains "$out" "captured:" "a terminal result is still captured durably"
assert_contains "$out" "retired: ends-src" "the runner reports the adapter-driven retirement"
assert_absent "$HTERM/state/procevent/ends-src.source" "an adapter-classified terminal result retires its registration"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/ends-src.claim" "terminal retirement releases this runner's own claim"
assert_contains "$(wake_payloads "$HTERM")" "procevent endnow ends-src 1" "the terminal result is still announced"
[ "$(count_results "$HTERM" ends-src)" = 1 ] || fail "terminal retirement lost or duplicated the captured result"
TERMINAL_RESULT=$(first_result "$HTERM" ends-src || true)
assert_grep 'terminal payload' "$TERMINAL_RESULT" "automatic retirement retains the captured output verbatim"
out=$(pe_adapter "$HTERM" reconcile)
assert_contains "$out" "started=0" "a retired terminal source is never restarted"
assert_contains "$out" "published=1" "an unhandled terminal result is still re-announced until acknowledged"
[ "$(count_results "$HTERM" ends-src)" = 1 ] || fail "a retired terminal source ran its poll again"
out=$(pe_adapter "$HTERM" retire ends-src)
assert_contains "$out" "retired: ends-src" "explicit retirement stays supported and idempotent after automatic retirement"
ack_out=$(pe_adapter "$HTERM" handled ends-src 1)
assert_contains "$ack_out" "handled: ends-src 1" "a terminal result is acknowledged through the owned interface"
out=$(pe_adapter "$HTERM" reconcile)
assert_contains "$out" "published=0" "an acknowledged terminal result stops being re-announced"
pass "an adapter-classified terminal result is captured once, announced, and retires its source automatically"

HOPEN="$TMP_ROOT/hopen"; new_home "$HOPEN"
PE_TRACKED+=("$HOPEN|open-src")
pe_adapter "$HOPEN" register openended open-src -- /bin/echo "open payload" >/dev/null
out=$(pe_adapter "$HOPEN" start open-src)
assert_contains "$out" "captured:" "a result from an adapter with no terminal verdict is captured"
assert_not_contains "$out" "retired:" "an adapter with no terminal verdict never retires its source"
assert_present "$HOPEN/state/procevent/open-src.source" "a source with no terminal verdict stays armed"
pe_adapter "$HOPEN" retire open-src >/dev/null
pass "a source stays armed unless its own adapter classifies the result terminal"

HREPLACE="$TMP_ROOT/hreplace"; new_home "$HREPLACE"
PE_TRACKED+=("$HREPLACE|replace-src")
OLD_TRIGGER="$TMP_ROOT/replace-old-trigger"
pe_adapter "$HREPLACE" register endnow replace-src -- "$BLOCKER" "$OLD_TRIGGER" "old terminal payload" >/dev/null
pe_adapter "$HREPLACE" start replace-src > "$TMP_ROOT/replace-old.out" 2>&1 &
replace_old_pid=$!
wait_for "$FM_PROCEVENT_CLAIM_ROOT/replace-src.claim" || fail "the old registration was never claimed"
pe_adapter "$HREPLACE" register openended replace-src -- /bin/echo "replacement payload" >/dev/null
touch "$OLD_TRIGGER"
wait "$replace_old_pid" || fail "the old terminal runner failed"
assert_contains "$(cat "$TMP_ROOT/replace-old.out")" "cannot retire terminal source" \
  "an old runner refuses to retire a replacement registration"
assert_present "$HREPLACE/state/procevent/replace-src.source" \
  "a replacement registration survives the old runner's terminal result"
assert_contains "$(cat "$HREPLACE/state/procevent/replace-src.source")" "adapter=openended" \
  "the surviving registration is the replacement generation"
out=$(pe_adapter "$HREPLACE" start replace-src)
assert_contains "$out" "captured:" "the replacement registration remains independently runnable"
[ "$(count_results "$HREPLACE" replace-src)" = 2 ] \
  || fail "the replacement generation did not capture its own result"
pe_adapter "$HREPLACE" retire replace-src >/dev/null
pass "terminal retirement preserves and releases a concurrently replaced registration"

HRETFAIL="$TMP_ROOT/hretfail"; new_home "$HRETFAIL"
PE_TRACKED+=("$HRETFAIL|retire-fail-src")
FAIL_RM_BIN=$(fm_fakebin "$TMP_ROOT/retire-fail-bin")
REAL_RM=$(command -v rm)
export REAL_RM
cat > "$FAIL_RM_BIN/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in */retire-fail-src.source) exit 1 ;; esac
done
exec "$REAL_RM" "$@"
SH
chmod +x "$FAIL_RM_BIN/rm"
pe_adapter "$HRETFAIL" register endnow retire-fail-src -- /bin/echo "one terminal payload" >/dev/null
out=$(PATH="$FAIL_RM_BIN:$PATH" pe_adapter "$HRETFAIL" start retire-fail-src 2>&1)
assert_contains "$out" "cannot retire terminal source" "a failed registration removal is reported"
assert_present "$HRETFAIL/state/procevent/retire-fail-src.source" \
  "failed retirement preserves the exact registration"
assert_present "$FM_PROCEVENT_CLAIM_ROOT/retire-fail-src.claim" \
  "failed retirement preserves its terminal ownership claim"
out=$(PATH="$FAIL_RM_BIN:$PATH" pe_adapter "$HRETFAIL" reconcile)
assert_contains "$out" "started=0" "failed terminal retirement never restarts the poll"
[ "$(count_results "$HRETFAIL" retire-fail-src)" = 1 ] \
  || fail "failed retirement allowed recurring terminal capture"
pe_adapter "$HRETFAIL" reconcile >/dev/null
assert_absent "$HRETFAIL/state/procevent/retire-fail-src.source" \
  "repeated retirement removes the same registration once removal recovers"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/retire-fail-src.claim" \
  "the claim releases only after that registration is removed"
[ "$(count_results "$HRETFAIL" retire-fail-src)" = 1 ] \
  || fail "retirement recovery reran the terminal source"
pass "failed terminal retirement is fail-closed and idempotently recoverable"

# --- end-user-aligned regression: one Send & End, one captured result -------
# The dogfood defect: a real armed Lavish source received one human `Send & End`
# action, and the runner captured four results - the human's real feedback, then
# recurring empty ended sessions - because it kept restarting a source whose own
# adapter already knew the session had ended. Driven through the adapter's own
# arm command against a stand-in for the published poll shape, so registration,
# the runner, capture, publication, and retirement all run for real.
HLT="$TMP_ROOT/hlt"; new_home "$HLT"
LAVISH_BIN=$(fm_fakebin "$TMP_ROOT/lavish-stub")
LAVISH_POLL_COUNT="$TMP_ROOT/lavish-poll-count"
export LAVISH_POLL_COUNT
cat > "$LAVISH_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
# Stand-in for `lavish-axi poll <file>` around a human `Send & End`: the final
# feedback is delivered exactly once carrying session_ended, and every later
# poll returns an empty ended session immediately.
n=$(cat "$LAVISH_POLL_COUNT" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$LAVISH_POLL_COUNT"
if [ "$n" = 1 ]; then
  printf 'session:\n  file: /review.html\n  status: feedback\n  session_ended: true\n  ended_by: user\nfeedback[1]{text}:\n  ship it\n'
else
  printf 'session:\n  file: /review.html\n  status: ended\n  ended_by: user\n'
fi
SH
chmod +x "$LAVISH_BIN/lavish-axi"
REVIEW_ART="$TMP_ROOT/review.html"
printf '<h1>review</h1>\n' > "$REVIEW_ART"
lavish_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$REVIEW_ART")
PE_TRACKED+=("$HLT|$lavish_id")
PATH="$LAVISH_BIN:$PATH" FM_HOME="$HLT" "$ROOT/bin/fm-procevent-lavish.sh" arm "$REVIEW_ART" >/dev/null
for _ in $(seq 1 6); do
  PATH="$LAVISH_BIN:$PATH" pe "$HLT" reconcile >/dev/null
  sleep 0.3
done
[ "$(cat "$LAVISH_POLL_COUNT")" = 1 ] \
  || fail "an ended review kept being polled: $(cat "$LAVISH_POLL_COUNT") polls for one Send & End"
[ "$(count_results "$HLT" "$lavish_id")" = 1 ] \
  || fail "one Send & End produced $(count_results "$HLT" "$lavish_id") captured results"
[ "$(wake_payloads "$HLT" | sort -u | grep -c .)" = 1 ] \
  || fail "one Send & End produced more than one distinct event: $(wake_payloads "$HLT" | sort -u)"
assert_contains "$(wake_payloads "$HLT")" "procevent lavish $lavish_id 1" "the human's final feedback is announced"
assert_absent "$HLT/state/procevent/$lavish_id.source" "the ended review source retires automatically"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/$lavish_id.claim" "the ended review releases its owned claim"
LAVISH_RESULT=$(first_result "$HLT" "$lavish_id" || true)
assert_grep 'ship it' "$LAVISH_RESULT" "automatic retirement retains the human's final feedback"
out=$(PATH="$LAVISH_BIN:$PATH" FM_HOME="$HLT" "$ROOT/bin/fm-procevent-lavish.sh" retire "$REVIEW_ART")
assert_contains "$out" "retired: $lavish_id" "explicit adapter retirement stays supported after automatic retirement"
pass "one Send & End yields exactly one captured result, automatic retirement, and no recurring poll"

# --- end-user-aligned regression: an empty board close is not news ------------
# The captain's report: closing a review surface he had said nothing on still
# put a wake in his chat whose entire content was that nothing happened. The
# adapter now answers the runner's silence seam for exactly that shape, so the
# result is captured and recorded handled without ever being announced. Driven
# through the adapter's own arm command and the real runner, so registration,
# capture, the silence verdict, and retirement all run for real.
HEMPTY="$TMP_ROOT/hempty"; new_home "$HEMPTY"
EMPTY_BIN=$(fm_fakebin "$TMP_ROOT/lavish-empty-stub")
cat > "$EMPTY_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
# Stand-in for `lavish-axi poll <file>` when the captain closes a board he said
# nothing on: an ended session carrying no queued content at all.
printf 'session:\n  file: /quiet.html\n  status: ended\n  ended_by: user\n'
SH
chmod +x "$EMPTY_BIN/lavish-axi"
QUIET_ART="$TMP_ROOT/quiet-board.html"
printf '<h1>quiet</h1>\n' > "$QUIET_ART"
quiet_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$QUIET_ART")
PE_TRACKED+=("$HEMPTY|$quiet_id")
PATH="$EMPTY_BIN:$PATH" FM_HOME="$HEMPTY" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$QUIET_ART" >/dev/null
quiet_out=$(PATH="$EMPTY_BIN:$PATH" pe "$HEMPTY" start "$quiet_id" 2>&1)
assert_not_contains "$quiet_out" "not-autohandled" \
  "a durably silenced result was reported as still unacknowledged"
# The handled marker is written at exactly the point the wake would otherwise
# have been appended, so waiting on it - rather than on a fixed sleep - is what
# makes "no wake" a real observation instead of a race the test won by being
# early.
QUIET_HANDLED="$HEMPTY/state/procevent-inbox/$quiet_id.1.handled"
for _ in $(seq 1 100); do
  [ -f "$QUIET_HANDLED" ] && break
  sleep 0.1
done
[ -f "$QUIET_HANDLED" ] \
  || fail "a silenced result was not durably recorded handled, so a later reconcile would announce it"
[ "$(count_results "$HEMPTY" "$quiet_id")" = 1 ] \
  || fail "an empty board close captured $(count_results "$HEMPTY" "$quiet_id") results instead of one"
[ -z "$(wake_payloads "$HEMPTY")" ] \
  || fail "an empty board close woke the captain: $(wake_payloads "$HEMPTY")"
# Re-announcement is exactly what the handled marker exists to stop, so the
# silence has to survive the reconcile that would otherwise republish it.
PATH="$EMPTY_BIN:$PATH" pe "$HEMPTY" reconcile >/dev/null
sleep 0.3
[ -z "$(wake_payloads "$HEMPTY")" ] \
  || fail "a later reconcile re-announced a silenced empty board close: $(wake_payloads "$HEMPTY")"
assert_absent "$HEMPTY/state/procevent/$quiet_id.source" \
  "an empty board close still retires its ended source"
pass "an empty board close is captured and recorded handled without ever waking the captain"

# The other half of the same contract, on the same real path: a close that
# carries what the captain actually said must still reach him. Same runner, same
# adapter, one different response shape.
HANSWER="$TMP_ROOT/hanswer"; new_home "$HANSWER"
ANSWER_BIN=$(fm_fakebin "$TMP_ROOT/lavish-answer-stub")
cat > "$ANSWER_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
# Stand-in for `lavish-axi poll <file>` on a real `Send & End`: the captain's
# own choice, delivered with session_ended.
printf 'session:\n  file: /answered.html\n  status: feedback\n  session_ended: true\n  ended_by: user\nprompts[1]{tag,text,prompt}:\n  "choice","Option B","Context data: {\\"question\\":\\"noop-check-routing\\",\\"answer\\":\\"b\\"}"\n'
SH
chmod +x "$ANSWER_BIN/lavish-axi"
ANSWER_ART="$TMP_ROOT/answered-board.html"
printf '<h1>answered</h1>\n' > "$ANSWER_ART"
answer_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$ANSWER_ART")
PE_TRACKED+=("$HANSWER|$answer_id")
PATH="$ANSWER_BIN:$PATH" FM_HOME="$HANSWER" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$ANSWER_ART" >/dev/null
PATH="$ANSWER_BIN:$PATH" pe "$HANSWER" reconcile >/dev/null
wait_for "$HANSWER/state/.wake-queue" \
  || fail "a board close carrying the captain's real answer produced no wake"
assert_contains "$(wake_payloads "$HANSWER")" "procevent lavish $answer_id 1" \
  "a real board answer still reaches the captain"
[ ! -f "$HANSWER/state/procevent-inbox/$answer_id.1.handled" ] \
  || fail "a real board answer was recorded handled without ever being handled"
pass "a board close carrying the captain's real answer is still announced"

# --- end-user-aligned regression: a transient poll interruption is not news ---
# The dogfood defect: a live board listener can answer with exactly
#     error: Lavish Editor poll response was interrupted
#     code: SERVER_ERROR
# while the board's marks remain available. Firstmate registered raw poll output,
# so the generic runner captured that transient response and woke the whole fleet
# over what is really an internal retry. Every scenario below runs through the
# adapter's own arm command and the real runner, so registration, capture, and
# publication are exercised for real.
LAVISH_SCRIPTED_BIN=$(fm_fakebin "$TMP_ROOT/lavish-scripted-stub")
cat > "$LAVISH_SCRIPTED_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
# Stand-in for `lavish-axi poll <file>`, scripted per scenario: LAVISH_SCRIPT
# names the response for each successive poll, one word per poll, and its last
# word repeats forever. `interrupt` is the exact transient response the server
# returns while the board's marks stay available.
n=$(cat "$LAVISH_COUNT" 2>/dev/null || echo 0)
n=$((n + 1))
printf '%s\n' "$n" > "$LAVISH_COUNT"
read -r -a plan <<< "$LAVISH_SCRIPT"
i=$((n - 1))
[ "$i" -ge "${#plan[@]}" ] && i=$((${#plan[@]} - 1))
case "${plan[$i]}" in
  interrupt)
    printf 'error: Lavish Editor poll response was interrupted\ncode: SERVER_ERROR\n'; exit 1 ;;
  near-interrupt)
    printf 'error: Lavish Editor poll response was interrupted \ncode: SERVER_ERROR\n'; exit 1 ;;
  other-server-error)
    printf 'error: Lavish Editor session store is unavailable\ncode: SERVER_ERROR\n'; exit 1 ;;
  feedback)
    printf 'session:\n  file: /board.html\n  status: feedback\n  session_ended: true\n  ended_by: user\nfeedback[1]{text}:\n  ship it\n' ;;
  stream)
    printf 'x%.0s' {1..4096}
    printf 'ready\n' > "$LAVISH_STREAM_READY"
    while [ ! -e "$LAVISH_STREAM_RELEASE" ]; do sleep 0.05; done
    printf '\n' ;;
esac
SH
chmod +x "$LAVISH_SCRIPTED_BIN/lavish-axi"
export LAVISH_COUNT LAVISH_SCRIPT
# A bounded test override keeps the retry policy's real bound under test without
# making the suite wait out the production delay.
export FM_LAVISH_POLL_RETRY_DELAY=0

# Two interruptions, then the captain's real feedback: the retries are silent and
# only the feedback becomes a captured result and a check wake.
HRETRY="$TMP_ROOT/hretry"; new_home "$HRETRY"
RETRY_ART="$TMP_ROOT/retry-board.html"
printf '<h1>retry</h1>\n' > "$RETRY_ART"
retry_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$RETRY_ART")
PE_TRACKED+=("$HRETRY|$retry_id")
LAVISH_COUNT="$TMP_ROOT/retry-count"; LAVISH_SCRIPT="interrupt interrupt feedback"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HRETRY" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$RETRY_ART" >/dev/null
PATH="$LAVISH_SCRIPTED_BIN:$PATH" pe "$HRETRY" reconcile >/dev/null
wait_for "$HRETRY/state/.wake-queue" || fail "feedback after interrupted polls produced no wake"
[ "$(cat "$LAVISH_COUNT")" = 3 ] \
  || fail "the interrupted listener was polled $(cat "$LAVISH_COUNT") times, not the two quiet retries plus the delivering poll"
[ "$(count_results "$HRETRY" "$retry_id")" = 1 ] \
  || fail "a retried interruption produced $(count_results "$HRETRY" "$retry_id") captured results instead of one"
[ "$(wake_payloads "$HRETRY" | sort -u | grep -c .)" = 1 ] \
  || fail "a retried interruption woke the fleet: $(wake_payloads "$HRETRY" | sort -u)"
assert_contains "$(wake_payloads "$HRETRY")" "procevent lavish $retry_id 1" \
  "feedback arriving after quiet retries is captured and announced"
assert_grep 'ship it' "$(first_result "$HRETRY" "$retry_id")" \
  "the announced result is the captain's feedback, not the interruption"
pass "a transient Lavish poll interruption is retried quietly and never announced"

# Exhaustion is news: after the bounded retries the same exact response is
# captured and announced normally rather than being swallowed forever.
HEXH="$TMP_ROOT/hexh"; new_home "$HEXH"
EXH_ART="$TMP_ROOT/exhaust-board.html"
printf '<h1>exhaust</h1>\n' > "$EXH_ART"
exh_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$EXH_ART")
PE_TRACKED+=("$HEXH|$exh_id")
LAVISH_COUNT="$TMP_ROOT/exhaust-count"; LAVISH_SCRIPT="interrupt"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HEXH" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$EXH_ART" >/dev/null
PATH="$LAVISH_SCRIPTED_BIN:$PATH" pe "$HEXH" start "$exh_id" >/dev/null
[ "$(cat "$LAVISH_COUNT")" = 13 ] \
  || fail "the retry bound polled $(cat "$LAVISH_COUNT") times, not the first poll plus 12 bounded retries"
[ "$(count_results "$HEXH" "$exh_id")" = 1 ] \
  || fail "exhaustion produced $(count_results "$HEXH" "$exh_id") captured results instead of one"
assert_contains "$(wake_payloads "$HEXH")" "procevent lavish $exh_id 1" \
  "the interruption that survives the bound is announced normally"
assert_grep 'poll response was interrupted' "$(first_result "$HEXH" "$exh_id")" \
  "the announced result is the exact interruption the server returned"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HEXH" \
  "$ROOT/bin/fm-procevent-lavish.sh" retire "$EXH_ART" >/dev/null
pass "an interruption that outlives the bounded retries is captured and announced"

# A different SERVER_ERROR is a genuine error, never a retry: no fail-open drift
# from the one exact transient response this adapter owns.
HOTHER="$TMP_ROOT/hother"; new_home "$HOTHER"
OTHER_ART="$TMP_ROOT/other-board.html"
printf '<h1>other</h1>\n' > "$OTHER_ART"
other_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$OTHER_ART")
PE_TRACKED+=("$HOTHER|$other_id")
LAVISH_COUNT="$TMP_ROOT/other-count"; LAVISH_SCRIPT="other-server-error"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HOTHER" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$OTHER_ART" >/dev/null
PATH="$LAVISH_SCRIPTED_BIN:$PATH" pe "$HOTHER" start "$other_id" >/dev/null
[ "$(cat "$LAVISH_COUNT")" = 1 ] \
  || fail "an unrelated SERVER_ERROR was retried $(cat "$LAVISH_COUNT") times instead of surfacing at once"
assert_contains "$(wake_payloads "$HOTHER")" "procevent lavish $other_id 1" \
  "an unrelated SERVER_ERROR is captured and announced immediately"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HOTHER" \
  "$ROOT/bin/fm-procevent-lavish.sh" retire "$OTHER_ART" >/dev/null
pass "only the exact interruption is retried; an unrelated SERVER_ERROR still surfaces"
unset FM_LAVISH_POLL_RETRY_DELAY

# A whitespace variant is not the exact transient response and must surface on
# the first poll instead of drifting into the quiet retry policy.
HNEAR="$TMP_ROOT/hnear"; new_home "$HNEAR"
NEAR_ART="$TMP_ROOT/near-board.html"
printf '<h1>near</h1>\n' > "$NEAR_ART"
near_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$NEAR_ART")
PE_TRACKED+=("$HNEAR|$near_id")
LAVISH_COUNT="$TMP_ROOT/near-count"; LAVISH_SCRIPT="near-interrupt feedback"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HNEAR" FM_LAVISH_POLL_RETRY_DELAY=0 \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$NEAR_ART" >/dev/null
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HNEAR" pe "$HNEAR" start "$near_id" >/dev/null
[ "$(cat "$LAVISH_COUNT")" = 1 ] \
  || fail "a near-match interruption was retried instead of surfacing on its first poll"
assert_contains "$(wake_payloads "$HNEAR")" "procevent lavish $near_id 1" \
  "a whitespace variant of the interruption is captured and announced immediately"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HNEAR" \
  "$ROOT/bin/fm-procevent-lavish.sh" retire "$NEAR_ART" >/dev/null
pass "only the literal two-line interruption enters the quiet retry policy"

# The public arm boundary refuses invalid retry intervals before it publishes a
# source registration, rather than arming a listener that can only fail later.
HINVALID="$TMP_ROOT/hinvalid"; new_home "$HINVALID"
INVALID_ART="$TMP_ROOT/invalid-delay-board.html"
printf '<h1>invalid delay</h1>\n' > "$INVALID_ART"
invalid_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$INVALID_ART")
for invalid_delay in 61 invalid; do
  invalid_status=0
  invalid_out=$(PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HINVALID" \
    FM_LAVISH_POLL_RETRY_DELAY="$invalid_delay" \
    "$ROOT/bin/fm-procevent-lavish.sh" arm "$INVALID_ART" 2>&1) || invalid_status=$?
  [ "$invalid_status" -ne 0 ] \
    || fail "arm accepted invalid retry delay: $invalid_delay"
  assert_contains "$invalid_out" "must be whole seconds from 0 to 60" \
    "arm explains the rejected retry delay"
  assert_absent "$HINVALID/state/procevent/$invalid_id.source" \
    "arm publishes no source registration for an invalid retry delay"
done
pass "arm rejects malformed and out-of-range retry delays before registration"

# Shell-safe cleanup must preserve a valid TMPDIR containing an apostrophe.
QUOTED_TMPDIR="$TMP_ROOT/poll's-stage"
mkdir -p "$QUOTED_TMPDIR"
LAVISH_COUNT="$TMP_ROOT/quoted-count"; LAVISH_SCRIPT="feedback"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" TMPDIR="$QUOTED_TMPDIR" \
  "$ROOT/bin/fm-procevent-lavish.sh" poll "$NEAR_ART" >/dev/null
quoted_staged=("$QUOTED_TMPDIR"/fm-lavish-poll.*)
[ ! -e "${quoted_staged[0]}" ] \
  || fail "poll left its staged response behind in an apostrophe-containing TMPDIR"
pass "poll cleanup safely handles an apostrophe-containing TMPDIR"

HSTREAM="$TMP_ROOT/hstream"; new_home "$HSTREAM"
STREAM_ART="$TMP_ROOT/stream-board.html"
STREAM_TMPDIR="$TMP_ROOT/stream-stage"
LAVISH_STREAM_READY="$TMP_ROOT/stream-ready"
LAVISH_STREAM_RELEASE="$TMP_ROOT/stream-release"
mkdir -p "$STREAM_TMPDIR"
printf '<h1>stream</h1>\n' > "$STREAM_ART"
stream_id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$STREAM_ART")
PE_TRACKED+=("$HSTREAM|$stream_id")
LAVISH_COUNT="$TMP_ROOT/stream-count"; LAVISH_SCRIPT="stream"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HSTREAM" \
  "$ROOT/bin/fm-procevent-lavish.sh" arm "$STREAM_ART" >/dev/null
PATH="$LAVISH_SCRIPTED_BIN:$PATH" TMPDIR="$STREAM_TMPDIR" \
  LAVISH_STREAM_READY="$LAVISH_STREAM_READY" LAVISH_STREAM_RELEASE="$LAVISH_STREAM_RELEASE" \
  FM_PROCEVENT_MAX_OUTPUT_BYTES=100 pe "$HSTREAM" reconcile >/dev/null
wait_for "$LAVISH_STREAM_READY" || fail "streaming poll did not start"
stream_staged=("$STREAM_TMPDIR"/fm-lavish-poll.*)
[ -e "${stream_staged[0]}" ] || fail "streaming poll created no classifier staging file"
[ "$(wc -c < "${stream_staged[0]}" | tr -d ' ')" -le 100 ] \
  || fail "streaming poll exceeded its bounded classifier staging"
: > "$LAVISH_STREAM_RELEASE"
wait_for "$HSTREAM/state/.wake-queue" || fail "streaming poll produced no wake"
stream_result=$(first_result "$HSTREAM" "$stream_id" || true)
[ "$(wc -c < "$stream_result" | tr -d ' ')" -le 100 ] \
  || fail "streaming poll bypassed the runner output bound"
PATH="$LAVISH_SCRIPTED_BIN:$PATH" FM_HOME="$HSTREAM" \
  "$ROOT/bin/fm-procevent-lavish.sh" retire "$STREAM_ART" >/dev/null
pass "Lavish classification staging stays bounded while nonmatches stream"

# --- end-user-aligned regression: the exact drain-before-handling restart cut
# Reproduces the confirmed defect through the public interface end to end: a
# real blocking source completes, its result is captured and published, the
# wake is drained without any handling, a replacement session's reconcile must
# resurface the exact same source and sequence, and only the owned handling
# interface may retire it - safely and without ever authorizing a paired
# effect a second time.
HW="$TMP_ROOT/hw"; new_home "$HW"
TRIGW="$TMP_ROOT/trigger-restart-cut"
pe_register "$HW" lavish restart-cut-src -- "$BLOCKER" "$TRIGW" "restart cut payload" >/dev/null
pe "$HW" reconcile >/dev/null
sleep 0.5
: > "$TRIGW"
wait_for "$HW/state/.wake-queue" || fail "the restart-cut source published no event"
assert_contains "$(wake_payloads "$HW")" "procevent lavish restart-cut-src 1" \
  "capture and publish reaches the wake queue before any handling"

# Retire the registration now that the source has completed and captured its
# one result. The fixture's trigger file persists on disk, so a still-armed
# registration would let every further reconcile call restart the blocker and
# capture a fresh generation; retiring leaves only the durable inbox and wake
# state under test, matching the exact restart cut - the source side is done,
# only the handling side is still open.
pe "$HW" retire restart-cut-src >/dev/null

# Drain the wake without handling it: the end-user experience of a session
# reading the wake queue at turn end without yet acting on this specific line.
mv "$HW/state/.wake-queue" "$HW/state/.wake-queue.drained-unhandled"
[ -z "$(wake_payloads "$HW")" ] || fail "the wake queue was not actually drained"

# Simulate a replacement Firstmate session: reconcile runs cold, as it would on
# a fresh process with no memory of the prior turn.
out=$(pe "$HW" reconcile)
assert_contains "$out" "published=1" \
  "a replacement session's reconcile resurfaces a drained-but-unhandled result"
assert_contains "$(wake_payloads "$HW")" "procevent lavish restart-cut-src 1" \
  "the exact same captured source and sequence resurfaces, never a substitute"

# Acknowledge handling through the owned interface.
ack_out=$(pe "$HW" handled restart-cut-src 1)
assert_contains "$ack_out" "handled: restart-cut-src 1" \
  "the first acknowledgement newly authorizes the paired effect"

mv "$HW/state/.wake-queue" "$HW/state/.wake-queue.post-handle"
out=$(pe "$HW" reconcile)
assert_contains "$out" "published=0" \
  "a later reconcile does not resurface a result once it is durably handled"
[ -z "$(wake_payloads "$HW")" ] || fail "a handled result was announced again: $(wake_payloads "$HW")"

auth_count=0
for _ in 1 2 3; do
  repeat_ack=$(pe "$HW" handled restart-cut-src 1)
  assert_contains "$repeat_ack" "already-handled: restart-cut-src 1" "repeated acknowledgement stays safe and idempotent"
  case "$repeat_ack" in handled:*) auth_count=$((auth_count + 1)) ;; esac
done
[ "$auth_count" -eq 0 ] || fail "a result already durably handled was authorized again: count=$auth_count"
pass "a drained-but-unhandled result survives a replacement session and is retired only by explicit handling, never twice"

HP="$TMP_ROOT/hp"; new_home "$HP"
mkdir -p "$HP/state/procevent-inbox"
for seq in 10 2 1; do
  printf '%s\n' "$seq" > "$HP/state/procevent-inbox/ordered-src.$seq.result"
  printf 'lavish\n' > "$HP/state/procevent-inbox/ordered-src.$seq.adapter"
  chmod 0600 "$HP/state/procevent-inbox/ordered-src.$seq.result" "$HP/state/procevent-inbox/ordered-src.$seq.adapter"
done
pending=$(bash -c '. "$1/bin/fm-procevent-lib.sh"; fm_procevent_pending "$2"' _ "$ROOT" "$HP/state")
expected=$(printf '%s\n' \
  "$HP/state/procevent-inbox/ordered-src.1.result" \
  "$HP/state/procevent-inbox/ordered-src.2.result" \
  "$HP/state/procevent-inbox/ordered-src.10.result")
[ "$pending" = "$expected" ] || fail "pending results were not emitted in numeric sequence order: $pending"
pe "$HP" reconcile >/dev/null
deduped=$(FM_HOME="$HP" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_wake_print_deduped "$2/state/.wake-queue" | awk -F "\t" "{print \$5}"
' _ "$ROOT" "$HP")
expected=$(printf '%s\n' \
  'check: procevent lavish ordered-src 1' \
  'check: procevent lavish ordered-src 2' \
  'check: procevent lavish ordered-src 10')
[ "$deduped" = "$expected" ] || fail "distinct result generations were coalesced or reordered: $deduped"
pass "pending results preserve numeric order and distinct wake identity"

# --- two homes cannot both own one canonical source -------------------------
HA="$TMP_ROOT/ha"; HB="$TMP_ROOT/hb"; new_home "$HA"; new_home "$HB"
TRIG2="$TMP_ROOT/trigger-two"
pe_register "$HA" lavish shared-src -- "$BLOCKER" "$TRIG2" "shared" >/dev/null
pe_register "$HB" lavish shared-src -- "$BLOCKER" "$TRIG2" "shared" >/dev/null
pe "$HA" reconcile >/dev/null
sleep 0.5
out=$(pe "$HB" start shared-src)
assert_contains "$out" "already owned" "a second home cannot own a source another home already owns"
[ -z "$(wake_payloads "$HB")" ] || fail "the losing home published an event"
pass "one owner per canonical source across homes"

# A source whose child never completes must not survive retirement. This is the
# leak that reparented four orphaned runners: the fixture directory was removed
# while the detached child kept blocking, with nothing left to reap it.
runner_pid=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/shared-src.claim" 2>/dev/null)
[ -n "$runner_pid" ] || fail "no runner pid recorded for the blocked source"
kill -0 "$runner_pid" 2>/dev/null || fail "the blocked runner is not live before retirement"
pe "$HA" retire shared-src >/dev/null
for _ in $(seq 1 40); do kill -0 "$runner_pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$runner_pid" 2>/dev/null && fail "retire left the blocked runner alive"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/shared-src.claim" "retire releases the claim"
pass "retiring a never-completing source stops its runner and its blocked child"

# reconcile must also stop a runner whose registration was removed out from under it.
TRIG4="$TMP_ROOT/trigger-four"
HZ="$TMP_ROOT/hz"; new_home "$HZ"
pe_register "$HZ" lavish orphan-src -- "$BLOCKER" "$TRIG4" "orphan" >/dev/null
pe "$HZ" reconcile >/dev/null
sleep 0.5
orphan_pid=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/orphan-src.claim" 2>/dev/null)
if [ -z "$orphan_pid" ] || ! kill -0 "$orphan_pid" 2>/dev/null; then
  fail "orphan fixture runner did not start"
fi
rm -f "$HZ/state/procevent/orphan-src.source"
out=$(pe "$HZ" reconcile)
assert_contains "$out" "stopped=1" "reconcile stops a runner whose registration was removed"
for _ in $(seq 1 40); do kill -0 "$orphan_pid" 2>/dev/null || break; sleep 0.1; done
kill -0 "$orphan_pid" 2>/dev/null && fail "reconcile left an orphaned runner alive"
pass "reconcile reaps a runner whose source registration is gone"

# --- a stale claim is reclaimable, a live one is not ------------------------
CLAIM="$FM_PROCEVENT_CLAIM_ROOT/stale-src.claim"
mkdir -p "$FM_PROCEVENT_CLAIM_ROOT"
HC="$TMP_ROOT/hc"; new_home "$HC"
printf '%s\n%s\nstale-token\nstale-identity\n' "$HC" "999999" > "$CLAIM"
chmod 0600 "$CLAIM"
pe_register "$HC" lavish stale-src -- /bin/echo recovered >/dev/null
printf 'partial sensitive output\n' > "$HC/state/procevent/.stale-src.stale-token.output"
chmod 0600 "$HC/state/procevent/.stale-src.stale-token.output"
out=$(pe "$HC" start stale-src)
assert_contains "$out" "captured:" "a claim whose runner is gone is reclaimable"
assert_absent "$CLAIM" "the replacement claim generation is released after completion"
assert_absent "$HC/state/procevent/.stale-src.stale-token.output" "stale claim recovery removes its abandoned staging generation"
pass "stale-owner recovery removes abandoned output without displacing a live owner"

HC_OLD="$TMP_ROOT/hc-old"; new_home "$HC_OLD"
HC_NEW="$TMP_ROOT/hc-new"; new_home "$HC_NEW"
HC_OLD_STATE="$TMP_ROOT/hc-old-state"
mkdir -p "$HC_OLD_STATE/procevent"
printf '%s\n%s\ncross-home-token\ncross-home-identity\n%s\n' \
  "$HC_OLD" "999999" "$HC_OLD_STATE/procevent" > "$FM_PROCEVENT_CLAIM_ROOT/cross-home-src.claim"
chmod 0600 "$FM_PROCEVENT_CLAIM_ROOT/cross-home-src.claim"
printf 'partial cross-home output\n' > "$HC_OLD_STATE/procevent/.cross-home-src.cross-home-token.output"
chmod 0600 "$HC_OLD_STATE/procevent/.cross-home-src.cross-home-token.output"
pe_register "$HC_NEW" lavish cross-home-src -- /bin/echo recovered >/dev/null
out=$(pe "$HC_NEW" start cross-home-src)
assert_contains "$out" "captured:" "a second home can replace a stale source owner"
assert_absent "$HC_OLD_STATE/procevent/.cross-home-src.cross-home-token.output" "cross-home reclaim removes the old generation's recorded staging file"
pass "cross-home stale recovery removes abandoned output from the old state directory"

HR="$TMP_ROOT/hr"; new_home "$HR"
RACE_TRIGGER="$TMP_ROOT/race-trigger"
RACE_LOG="$TMP_ROOT/race-executions"
RACE_BLOCKER="$TMP_ROOT/race-blocker.sh"
cat > "$RACE_BLOCKER" <<'SH'
#!/usr/bin/env bash
printf 'started\n' >> "$1"
while [ ! -e "$2" ]; do sleep 0.05; done
printf 'race result\n'
SH
chmod +x "$RACE_BLOCKER"
pe_register "$HR" lavish race-src -- "$RACE_BLOCKER" "$RACE_LOG" "$RACE_TRIGGER" >/dev/null
printf '%s\n%s\nold-token\nold-identity\n' "$TMP_ROOT/gone-home" 999999 > "$FM_PROCEVENT_CLAIM_ROOT/race-src.claim"
chmod 0600 "$FM_PROCEVENT_CLAIM_ROOT/race-src.claim"
race_pids=()
for _ in $(seq 1 24); do
  pe "$HR" start race-src >/dev/null &
  race_pids+=("$!")
done
wait_for "$RACE_LOG" || fail "no contender acquired the stale claim"
sleep 0.5
[ "$(wc -l < "$RACE_LOG" | tr -d ' ')" = 1 ] || fail "stale-claim race started more than one runner"
: > "$RACE_TRIGGER"
for race_pid in "${race_pids[@]}"; do wait "$race_pid" 2>/dev/null || true; done
pass "concurrent stale-claim replacement starts exactly one runner"

# --- a crashed runner leader must not make its live child group look stale ---
# The runner is its own process group leader, so SIGKILL on the leader alone
# leaves the blocking source child running in that group. Classifying the
# missing leader as stale would release ownership and start a second poller
# against one canonical source, which for a destructive source means two
# concurrent long polls racing on the same session. The surviving group must be
# stopped before ownership can move.
HG="$TMP_ROOT/hg"; new_home "$HG"
ORPHAN_TRIGGER="$TMP_ROOT/orphan-trigger"
ORPHAN_LOG="$TMP_ROOT/orphan-executions"
ORPHAN_GROUP="$TMP_ROOT/orphan-group"
ORPHAN_OVERLAP="$TMP_ROOT/orphan-overlap"
ORPHAN_BLOCKER="$TMP_ROOT/orphan-blocker.sh"
cat > "$ORPHAN_BLOCKER" <<'SH'
#!/usr/bin/env bash
printf 'started\n' >> "$1"
if [ -s "$3" ]; then
  IFS= read -r old_group < "$3"
  if kill -0 "-$old_group" 2>/dev/null; then
    printf 'overlap\n' > "$4"
  fi
fi
while [ ! -e "$2" ]; do sleep 0.05; done
printf 'orphan result\n'
SH
chmod +x "$ORPHAN_BLOCKER"
pe_register "$HG" lavish orphan-src -- \
  "$ORPHAN_BLOCKER" "$ORPHAN_LOG" "$ORPHAN_TRIGGER" "$ORPHAN_GROUP" "$ORPHAN_OVERLAP" >/dev/null
pe "$HG" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/orphan-src.claim" || fail "leader-crash fixture never claimed its source"
wait_for "$ORPHAN_LOG" || fail "leader-crash fixture source never started"
orphan_leader=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/orphan-src.claim")
case "$orphan_leader" in ''|*[!0-9]*) fail "could not read the runner leader pid: $orphan_leader" ;; esac
printf '%s\n' "$orphan_leader" > "$ORPHAN_GROUP"

kill -KILL "$orphan_leader" 2>/dev/null || fail "could not kill the runner leader"
for _ in $(seq 1 50); do kill -0 "$orphan_leader" 2>/dev/null || break; sleep 0.1; done
kill -0 "$orphan_leader" 2>/dev/null && fail "the runner leader survived SIGKILL"
kill -0 -"$orphan_leader" 2>/dev/null || fail "fixture invalid: the owned child group did not survive the leader"

orphan_out=$(pe "$HG" reconcile)
kill -0 -"$orphan_leader" 2>/dev/null \
  && fail "reconcile left the crashed generation's process group alive: $orphan_out"
sleep 0.5
assert_absent "$ORPHAN_OVERLAP" "no replacement source starts while the crashed generation remains alive"
case "$orphan_out" in
  *"started=1"*)
    # The replacement is detached: it records its own claim and execs its source
    # after reconcile has already returned, so both effects must be waited for
    # rather than snapshotted behind the settle window above.
    wait_for "$FM_PROCEVENT_CLAIM_ROOT/orphan-src.claim" \
      || fail "a replacement runner started without recording its own claim"
    wait_for_lines "$ORPHAN_LOG" 2 \
      || fail "the replacement runner never started its source: $(cat "$ORPHAN_LOG")"
    [ "$(wc -l < "$ORPHAN_LOG" | tr -d ' ')" = 2 ] \
      || fail "reconcile did not start exactly one replacement source: $(cat "$ORPHAN_LOG")"
    ;;
  *"started=0"*)
    [ -e "$FM_PROCEVENT_CLAIM_ROOT/orphan-src.claim" ] \
      || fail "refusing to replace must preserve the claim for retry: $orphan_out"
    [ "$(wc -l < "$ORPHAN_LOG" | tr -d ' ')" = 1 ] \
      || fail "reconcile started a source while refusing replacement: $(cat "$ORPHAN_LOG")"
    ;;
  *) fail "unexpected reconcile result for a crashed leader: $orphan_out" ;;
esac
: > "$ORPHAN_TRIGGER"
pe "$HG" retire orphan-src >/dev/null
pass "a crashed runner leader never lets a live owned group be reclaimed as stale"

# Counterexample: a genuinely dead generation - no leader and no surviving
# group - must still be reclaimable, or crash recovery would deadlock.
HG2="$TMP_ROOT/hg2"; new_home "$HG2"
DEAD_TRIGGER="$TMP_ROOT/dead-gen-trigger"
DEAD_LOG="$TMP_ROOT/dead-gen-executions"
pe_register "$HG2" lavish dead-gen-src -- "$RACE_BLOCKER" "$DEAD_LOG" "$DEAD_TRIGGER" >/dev/null
printf '%s\n%s\ndead-token\ndead-identity\n%s\n' "$HG2" 999999 "$HG2/state/procevent" \
  > "$FM_PROCEVENT_CLAIM_ROOT/dead-gen-src.claim"
chmod 0600 "$FM_PROCEVENT_CLAIM_ROOT/dead-gen-src.claim"
dead_out=$(pe "$HG2" reconcile)
assert_contains "$dead_out" "started=1" "a generation with no leader and no group is still reclaimable"
wait_for "$DEAD_LOG" || fail "the replacement source never started for a truly dead generation"
: > "$DEAD_TRIGGER"
pe "$HG2" retire dead-gen-src >/dev/null
pass "a truly dead generation with no surviving group is still safely reclaimed"

HJ="$TMP_ROOT/hj"; new_home "$HJ"
TORN_TRIGGER="$TMP_ROOT/torn-trigger"
pe_register "$HJ" lavish torn-src -- "$BLOCKER" "$TORN_TRIGGER" "torn" >/dev/null
pe "$HJ" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/torn-src.claim" || fail "torn-read fixture runner did not claim its source"
awk 'NR == 3 { print "replacement-token"; next } { print }' \
  "$FM_PROCEVENT_CLAIM_ROOT/torn-src.claim" > "$TMP_ROOT/torn-next.claim"
chmod 0600 "$TMP_ROOT/torn-next.claim"
TORN_READY="$TMP_ROOT/torn-lock-ready"
TORN_RELEASE="$TMP_ROOT/torn-lock-release"
hold_source_lock torn-src "$TORN_READY" "$TORN_RELEASE"
torn_holder_pid=$HOLDER_PID
wait_for "$TORN_READY" || fail "could not hold the torn-read source boundary"
pe "$HJ" list > "$TMP_ROOT/torn-list.out" &
torn_list_pid=$!
sleep 0.2
kill -0 "$torn_list_pid" 2>/dev/null || fail "claim reader escaped the source boundary during replacement"
mv "$TMP_ROOT/torn-next.claim" "$FM_PROCEVENT_CLAIM_ROOT/torn-src.claim"
: > "$TORN_RELEASE"
wait "$torn_list_pid" || fail "claim reader failed after serialized replacement"
wait "$torn_holder_pid" || fail "torn-read source boundary holder failed"
assert_contains "$(cat "$TMP_ROOT/torn-list.out")" "live" "claim reader observes one coherent replacement generation"
pe "$HJ" retire torn-src >/dev/null
pass "claim replacement cannot produce a torn ownership snapshot"

HK="$TMP_ROOT/hk"; new_home "$HK"
START_LOG="$TMP_ROOT/retire-start-executions"
START_BLOCKER="$TMP_ROOT/retire-start-blocker.sh"
cat > "$START_BLOCKER" <<'SH'
#!/usr/bin/env bash
printf 'started\n' >> "$1"
sleep 30
SH
chmod +x "$START_BLOCKER"
pe_register "$HK" lavish retire-start-src -- "$START_BLOCKER" "$START_LOG" >/dev/null
START_READY="$TMP_ROOT/retire-start-lock-ready"
START_RELEASE="$TMP_ROOT/retire-start-lock-release"
hold_source_lock retire-start-src "$START_READY" "$START_RELEASE"
retire_start_holder_pid=$HOLDER_PID
wait_for "$START_READY" || fail "could not hold the retire-start source boundary"
pe "$HK" start retire-start-src > "$TMP_ROOT/retire-start.out" 2>&1 &
retire_start_pid=$!
sleep 0.2
kill -0 "$retire_start_pid" 2>/dev/null || fail "start did not wait for the source lifecycle boundary"
rm -f "$HK/state/procevent/retire-start-src.source"
: > "$START_RELEASE"
wait "$retire_start_pid" 2>/dev/null || true
wait "$retire_start_holder_pid" || fail "retire-start source boundary holder failed"
assert_absent "$START_LOG" "a start queued before retirement must revalidate the registration"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/retire-start-src.claim" "retirement cannot leave a late claim"
pass "retirement and start share one serialized lifecycle boundary"

HI="$TMP_ROOT/hi"; new_home "$HI"
pe_register "$HI" lavish reused-src -- /bin/true >/dev/null
sleep 60 &
innocent_pid=$!
printf '%s\n%s\nreused-token\nnot-the-live-process-identity\n' \
  "$HI" "$innocent_pid" > "$FM_PROCEVENT_CLAIM_ROOT/reused-src.claim"
chmod 0600 "$FM_PROCEVENT_CLAIM_ROOT/reused-src.claim"
pe "$HI" retire reused-src >/dev/null
kill -0 "$innocent_pid" 2>/dev/null || fail "retirement signaled a PID whose identity did not match the claim"
kill "$innocent_pid" 2>/dev/null || true
wait "$innocent_pid" 2>/dev/null || true
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/reused-src.claim" "retirement releases the exact reused-pid claim"
pass "PID reuse cannot signal an unrelated process"

HL="$TMP_ROOT/hl"; new_home "$HL"
IDENTITY_TRIGGER="$TMP_ROOT/identity-trigger"
pe_register "$HL" lavish identity-src -- "$BLOCKER" "$IDENTITY_TRIGGER" "identity" >/dev/null
pe "$HL" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/identity-src.claim" || fail "identity fixture runner did not claim its source"
identity_pid=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/identity-src.claim")
IDENTITY_FAKEBIN=$(fm_fakebin "$TMP_ROOT/identity-tools")
cat > "$IDENTITY_FAKEBIN/ps" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$IDENTITY_FAKEBIN/ps"
identity_status=0
identity_out=$(PATH="$IDENTITY_FAKEBIN:$PATH" FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-proc" \
  pe "$HL" retire identity-src 2>&1) || identity_status=$?
[ "$identity_status" -ne 0 ] || fail "retirement succeeded despite uncertain live identity"
assert_contains "$identity_out" "source remains registered" "uncertain retirement reports preserved state"
kill -0 "$identity_pid" 2>/dev/null || fail "uncertain retirement signaled the runner"
assert_present "$HL/state/procevent/identity-src.source" "uncertain retirement preserves registration"
assert_present "$FM_PROCEVENT_CLAIM_ROOT/identity-src.claim" "uncertain retirement preserves claim generation"
pe "$HL" retire identity-src >/dev/null
pass "transient identity failure preserves the live source for retry"

HM="$TMP_ROOT/hm"; new_home "$HM"
SWEEP_TRIGGER_ONE="$TMP_ROOT/sweep-trigger-one"
SWEEP_TRIGGER_TWO="$TMP_ROOT/sweep-trigger-two"
pe_register "$HM" lavish sweep-one -- "$BLOCKER" "$SWEEP_TRIGGER_ONE" "sweep one" >/dev/null
pe_register "$HM" lavish sweep-two -- "$BLOCKER" "$SWEEP_TRIGGER_TWO" "sweep two" >/dev/null
pe "$HM" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/sweep-one.claim" || fail "home sweep fixture one did not start"
wait_for "$FM_PROCEVENT_CLAIM_ROOT/sweep-two.claim" || fail "home sweep fixture two did not start"
sweep_pid_one=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/sweep-one.claim")
sweep_pid_two=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/sweep-two.claim")
rm -f "$HM/state/procevent/sweep-two.source"
out=$(pe "$HM" sweep-home --preflight)
assert_contains "$out" "sweep preflight: ready" "home sweep preflight validates the full bounded snapshot"
assert_present "$HM/state/procevent/sweep-one.source" "home sweep preflight does not remove registrations"
assert_present "$FM_PROCEVENT_CLAIM_ROOT/sweep-one.claim" "home sweep preflight does not release claims"
out=$(pe "$HM" sweep-home)
assert_contains "$out" "swept: attempted=2" "home sweep retires registrations and owned claim-only sources"
for sweep_pid in "$sweep_pid_one" "$sweep_pid_two"; do
  for _ in $(seq 1 40); do kill -0 "$sweep_pid" 2>/dev/null || break; sleep 0.1; done
  kill -0 "$sweep_pid" 2>/dev/null && fail "home sweep left a runner alive"
done
assert_absent "$HM/state/procevent/sweep-one.source" "home sweep removes registrations"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/sweep-one.claim" "home sweep releases the first claim"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/sweep-two.claim" "home sweep releases a claim with no registration"
pass "bounded home sweep preflights then retires every locally owned source"

HN="$TMP_ROOT/hn"; HO="$TMP_ROOT/ho"; new_home "$HN"; new_home "$HO"
FOREIGN_TRIGGER="$TMP_ROOT/foreign-trigger"
pe_register "$HN" lavish foreign-src -- "$BLOCKER" "$FOREIGN_TRIGGER" "foreign" >/dev/null
pe_register "$HO" lavish foreign-src -- "$BLOCKER" "$FOREIGN_TRIGGER" "foreign" >/dev/null
pe "$HN" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/foreign-src.claim" || fail "foreign-owner fixture did not start"
foreign_pid=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/foreign-src.claim")
out=$(pe "$HO" sweep-home)
assert_contains "$out" "swept: attempted=1" "home sweep retires the local registration"
kill -0 "$foreign_pid" 2>/dev/null || fail "home sweep signaled a foreign-home runner"
assert_present "$FM_PROCEVENT_CLAIM_ROOT/foreign-src.claim" "home sweep preserves a foreign-home claim"
[ "$(sed -n '1p' "$FM_PROCEVENT_CLAIM_ROOT/foreign-src.claim")" = "$HN" ] || fail "home sweep changed foreign claim ownership"
assert_absent "$HO/state/procevent/foreign-src.source" "home sweep removes only the local registration"
pe "$HN" retire foreign-src >/dev/null
pass "home sweep leaves foreign-home claims and runners untouched"

HU="$TMP_ROOT/hu"; new_home "$HU"
SWEEP_UNCERTAIN_TRIGGER="$TMP_ROOT/sweep-uncertain-trigger"
pe_register "$HU" lavish sweep-uncertain -- "$BLOCKER" "$SWEEP_UNCERTAIN_TRIGGER" "uncertain" >/dev/null
pe "$HU" reconcile >/dev/null
wait_for "$FM_PROCEVENT_CLAIM_ROOT/sweep-uncertain.claim" || fail "uncertain sweep fixture did not start"
sweep_uncertain_pid=$(sed -n '2p' "$FM_PROCEVENT_CLAIM_ROOT/sweep-uncertain.claim")
sweep_status=0
sweep_out=$(PATH="$IDENTITY_FAKEBIN:$PATH" FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-sweep-proc" \
  pe "$HU" sweep-home 2>&1) || sweep_status=$?
[ "$sweep_status" -ne 0 ] || fail "home sweep succeeded with an uncertain runner identity"
assert_contains "$sweep_out" "home sweep preflight failed" "uncertain home sweep reports a retryable refusal"
kill -0 "$sweep_uncertain_pid" 2>/dev/null || fail "uncertain home sweep signaled the runner"
assert_present "$HU/state/procevent/sweep-uncertain.source" "uncertain home sweep preserves registration"
assert_present "$FM_PROCEVENT_CLAIM_ROOT/sweep-uncertain.claim" "uncertain home sweep preserves the claim"
pe "$HU" sweep-home >/dev/null
pass "home sweep refuses safely until runner identity is readable"

HV="$TMP_ROOT/hv"; new_home "$HV"
mkdir -p "$HV/state/procevent-inbox"
printf 'already captured\n' > "$HV/state/procevent-inbox/result-only.1.result"
sup=$(bash -c '. "$1/bin/fm-supervision-lib.sh"; fm_supervision_needed "$2" && echo yes || echo no' _ "$ROOT" "$HV/state")
assert_contains "$sup" no "registration-free results do not broaden continuous supervision"
out=$(pe "$HV" sweep-home)
assert_contains "$out" "swept: attempted=0" "result-only homes need no process cleanup"
pass "healthy runtime behavior remains registration-only"

# --- argv boundaries, stderr, exit status, bounds, malformed output ---------
HD="$TMP_ROOT/hd"; new_home "$HD"
TRIG3="$TMP_ROOT/trigger-three"
pe_register "$HD" lavish argv-src -- "$BLOCKER" "$TRIG3" "one arg with spaces" "second; rm -rf /tmp/nope" >/dev/null
pe "$HD" reconcile >/dev/null
: > "$TRIG3"
wait_for "$HD/state/.wake-queue" || fail "argv source published no event"
R=$(first_result "$HD" argv-src || true)
assert_grep 'one arg with spaces' "$R" "an argument containing spaces survives as one argument"
assert_grep 'second; rm -rf /tmp/nope' "$R" "a shell-looking argument is passed literally, never interpreted"
assert_absent /tmp/nope "no shell interpretation occurred"
assert_not_contains "$(wake_payloads "$HD")" "rm -rf" "argv content never reaches the event line"

newline_status=0
newline_out=$(pe_register "$HD" lavish newline-src -- /bin/echo $'first\nsecond' 2>&1) || newline_status=$?
[ "$newline_status" -ne 0 ] || fail "registration accepted an argv element containing a newline"
assert_contains "$newline_out" "cannot contain newlines" "newline rejection explains the unsupported representation"
assert_absent "$HD/state/procevent/newline-src.source" "newline rejection publishes no corrupt registration"
pass "registration rejects unrepresentable newline arguments"

HE="$TMP_ROOT/he"; new_home "$HE"
pe_register "$HE" lavish fail-src -- /bin/sh -c 'exit 7' >/dev/null
out=$(pe "$HE" start fail-src)
assert_contains "$out" "no-result" "a failing source with no output publishes nothing"
[ -z "$(wake_payloads "$HE")" ] || fail "a failing source published an event"
assert_present "$HE/state/procevent/fail-src.source" "a failing source stays registered for retry"
pass "nonzero exit with no output stays armed and silent"

HF="$TMP_ROOT/hf"; new_home "$HF"
# shellcheck disable=SC2016  # single quotes are deliberate: the child shell expands this.
pe_register "$HF" lavish big-src -- /bin/sh -c 'printf "x%.0s" $(seq 1 5000)' >/dev/null
FM_PROCEVENT_MAX_OUTPUT_BYTES=100 FM_HOME="$HF" "$ROOT/bin/fm-procevent.sh" start big-src >/dev/null 2>&1
RB=$(first_result "$HF" big-src || true)
[ -n "$RB" ] || fail "bounded output was not captured at all"
[ "$(wc -c < "$RB" | tr -d ' ')" -le 100 ] || fail "output bound was not enforced"
pass "oversized output is bounded rather than published whole or dropped"

HG="$TMP_ROOT/hg-live"; new_home "$HG"
NOISY="$TMP_ROOT/noisy.sh"
NOISY_PID="$TMP_ROOT/noisy.pid"
cat > "$NOISY" <<'SH'
#!/usr/bin/env bash
trap '' TERM PIPE
printf '%s\n' "$$" > "$1"
while :; do
  printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\n'
done
SH
chmod +x "$NOISY"
pe_register "$HG" lavish noisy-src -- "$NOISY" "$NOISY_PID" >/dev/null
FM_PROCEVENT_MAX_OUTPUT_BYTES=100 pe "$HG" reconcile >/dev/null
wait_for "$NOISY_PID" || fail "noisy source child did not start"
noisy_child=$(cat "$NOISY_PID")
staged=
for _ in $(seq 1 100); do
  for candidate in "$HG/state/procevent"/.noisy-src.*.output; do
    if [ -f "$candidate" ]; then staged=$candidate; break; fi
  done
  [ -n "$staged" ] && break
  sleep 0.1
done
[ -n "$staged" ] || fail "noisy source created no bounded staging file"
sleep 0.2
[ "$(wc -c < "$staged" | tr -d ' ')" -le 100 ] || fail "live staging exceeded the configured output bound"
pe "$HG" retire noisy-src >/dev/null
kill -0 "$noisy_child" 2>/dev/null && fail "TERM-resistant source child survived runner retirement"
assert_absent "$staged" "retirement removes the tracked partial staging file"
pass "live output stays bounded and retirement reaps the whole source group"

HBAD="$TMP_ROOT/hbad"; new_home "$HBAD"
pe_register "$HBAD" lavish bad-limit -- /bin/true >/dev/null
bad_limit_status=0
bad_limit_out=$(FM_PROCEVENT_MAX_OUTPUT_BYTES=invalid pe "$HBAD" start bad-limit 2>&1) || bad_limit_status=$?
[ "$bad_limit_status" -ne 0 ] || fail "an invalid output bound was accepted"
assert_contains "$bad_limit_out" "must be a nonnegative integer" "invalid output bound reports its contract"
assert_absent "$FM_PROCEVENT_CLAIM_ROOT/bad-limit.claim" "invalid output bound leaves no source claim"
pass "invalid output bounds fail closed"

# --- the Lavish adapter uses the published poll shape -----------------------
ART="$TMP_ROOT/artifact.html"
printf '<h1>fixture</h1>\n' > "$ART"
sid=$(FM_HOME="$TMP_ROOT/hg" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$ART")
case "$sid" in lavish-*) : ;; *) fail "adapter source id has an unexpected shape: $sid" ;; esac
sid2=$(FM_HOME="$TMP_ROOT/hg" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$ART")
[ "$sid" = "$sid2" ] || fail "adapter source id is not stable"
ART_ALIAS="$TMP_ROOT/artifact-alias.html"
ln -s "$ART" "$ART_ALIAS"
sid3=$(FM_HOME="$TMP_ROOT/hg" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$ART_ALIAS")
[ "$sid" = "$sid3" ] || fail "a final-component symlink produced a second source id"
ART_NEWLINE="$TMP_ROOT/line-ending"$'\n'
printf '<h1>newline fixture</h1>\n' > "$ART_NEWLINE"
printf '<h1>sibling fixture</h1>\n' > "$TMP_ROOT/line-ending"
newline_artifact_status=0
newline_artifact_out=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$ART_NEWLINE" 2>&1) || newline_artifact_status=$?
[ "$newline_artifact_status" -ne 0 ] || fail "Lavish source identity accepted an artifact path ending in a newline"
assert_contains "$newline_artifact_out" "cannot contain newlines" "Lavish rejects newline paths before canonicalization"
pass "the adapter derives physical identity without newline path corruption"

# Host replies are staged through the executable adapter while a fake generic
# restart boundary keeps the durable handoff observable. The fake Lavish binary
# records argv as framed data so multiline text is checked as one argument
# without inspecting implementation source.
REPLY_RUNTIME="$TMP_ROOT/reply-runtime"
REPLY_HOME="$TMP_ROOT/reply-home"
REPLY_BIN="$TMP_ROOT/reply-bin"
REPLY_LOG="$TMP_ROOT/reply-argv.log"
RESTART_LOG="$TMP_ROOT/reply-restart.log"
mkdir -p "$REPLY_RUNTIME/bin" "$REPLY_BIN"
new_home "$REPLY_HOME"
chmod 700 "$REPLY_HOME/state"
cp "$ROOT/bin/fm-procevent-lavish.sh" "$ROOT/bin/fm-procevent-lib.sh" \
  "$ROOT/bin/fm-pr-lib.sh" "$ROOT/bin/fm-wake-lib.sh" "$REPLY_RUNTIME/bin/"
cat > "$REPLY_RUNTIME/bin/fm-procevent.sh" <<'SH'
#!/usr/bin/env bash
file_identity() {
  if [ "$(uname)" = Darwin ]; then
    printf '%s:%s\n' "$(stat -f %d "$1")" "$(stat -f %i "$1")"
  else
    printf '%s:%s\n' "$(stat -c %d "$1")" "$(stat -c %i "$1")"
  fi
}
case "${1-}" in
  generation)
    source="$FM_HOME/state/procevent/$2.source"
    [ -f "$source" ] && [ ! -L "$source" ] || exit 1
    token=$(sed -n 's/^registration_token=//p' "$source")
    [ -n "$token" ] || exit 1
    printf 'generation: %s\n' "$token"
    ;;
  restart)
    printf '%s\n' "$*" >> "$RESTART_LOG"
    source="$FM_HOME/state/procevent/$2.source"
    if [ "${RESTART_REARM:-0}" = 1 ]; then
      saved="$FM_HOME/state/procevent/.reused-source"
      old_identity=$(file_identity "$source") || exit 1
      ln -- "$source" "$saved" && rm -f -- "$source" || exit 1
      new_token=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
      REPLACEMENT_TOKEN="$new_token" perl -0777 -e '
        my ($path) = @ARGV;
        open my $file, "+<", $path or exit 1;
        local $/;
        my $text = <$file>;
        $text =~ s/^registration_token=.*$/registration_token=$ENV{REPLACEMENT_TOKEN}/m or exit 1;
        seek $file, 0, 0 or exit 1;
        truncate $file, 0 or exit 1;
        print {$file} $text or exit 1;
      ' "$saved" || exit 1
      ln -- "$saved" "$source" && rm -f -- "$saved" || exit 1
      new_identity=$(file_identity "$source") || exit 1
      printf '%s %s\n' "$old_identity" "$new_identity" > "$REUSED_INODE_LOG"
    fi
    if [ "${3-}" = --if-generation ] \
      && [ "$(sed -n 's/^registration_token=//p' "$source")" != "${4-}" ]; then
      exit 1
    fi
    ;;
  retire)
    rm -f -- "$FM_HOME/state/procevent/$2.source"
    printf 'ready\n' > "$RETIRE_READY"
    while [ ! -e "$RETIRE_RELEASE" ]; do sleep 0.02; done
    ;;
  *) exit 97 ;;
esac
SH
chmod +x "$REPLY_RUNTIME/bin/fm-procevent.sh"
cat > "$REPLY_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
{
  printf 'BEGIN\n'
  for arg in "$@"; do
    printf 'ARG\n%s\nENDARG\n' "$arg"
  done
  printf 'END\n'
} >> "$REPLY_LOG"
case "${REPLY_BEHAVIOR:-success}" in
  block) while :; do sleep 1; done ;;
  commit) sleep 6; printf 'session:\n  file: fixture\n  status: waiting\n' ;;
  fail) exit 23 ;;
  success) printf 'session:\n  file: fixture\n  status: waiting\n' ;;
esac
SH
chmod +x "$REPLY_BIN/lavish-axi"
REPLY_ART="$TMP_ROOT/reply-artifact.html"
reply_status="$REPLY_HOME/state/reply-host.status"
printf '<h1>reply fixture</h1>\n' > "$REPLY_ART"
reply_id=$(FM_HOME="$REPLY_HOME" FM_ROOT_OVERRIDE="$REPLY_RUNTIME" \
  "$REPLY_RUNTIME/bin/fm-procevent-lavish.sh" source-id "$REPLY_ART")
FM_HOME="$REPLY_HOME" FM_ROOT_OVERRIDE="$REPLY_RUNTIME" \
  "$ROOT/bin/fm-procevent.sh" register lavish "$reply_id" -- \
  "$REPLY_RUNTIME/bin/fm-procevent-lavish.sh" poll "$REPLY_ART" >/dev/null

newline_reply_status=0
newline_reply_out=$(printf '\n\n' | FM_HOME="$REPLY_HOME" FM_ROOT_OVERRIDE="$REPLY_RUNTIME" \
  RESTART_LOG="$RESTART_LOG" "$REPLY_RUNTIME/bin/fm-procevent-lavish.sh" \
  reply "$REPLY_ART" 2>&1) || newline_reply_status=$?
[ "$newline_reply_status" -ne 0 ] || fail "newline-only reply input was accepted"
assert_contains "$newline_reply_out" "must not become empty" \
  "newline-only reply rejection explains the normalized empty value"
assert_absent "$REPLY_HOME/state/procevent/$reply_id.pending-reply" \
  "newline-only reply input poisoned pending reply state"
assert_absent "$RESTART_LOG" "newline-only reply input restarted the listener"

FM_HOME="$REPLY_HOME" FM_ROOT_OVERRIDE="$REPLY_RUNTIME" RESTART_LOG="$RESTART_LOG" \
  FM_LAVISH_HOST_STATUS_FILE="$reply_status" \
  "$REPLY_RUNTIME/bin/fm-procevent-lavish.sh" reply "$REPLY_ART" "First change applied." >/dev/null
printf '\nSecond change applied.\nWith detail.\n' | \
  FM_HOME="$REPLY_HOME" FM_ROOT_OVERRIDE="$REPLY_RUNTIME" RESTART_LOG="$RESTART_LOG" \
    FM_LAVISH_HOST_STATUS_FILE="$reply_status" \
    "$REPLY_RUNTIME/bin/fm-procevent-lavish.sh" reply "$REPLY_ART" >/dev/null
pending_reply="$REPLY_HOME/state/procevent/$reply_id.pending-reply"
inflight_reply="$REPLY_HOME/state/procevent/$reply_id.inflight-reply"
assert_present "$pending_reply" "reply did not leave one durable pending file"
if [ "$(uname)" = Darwin ]; then
  pending_reply_mode=$(stat -f %Lp "$pending_reply")
else
  pending_reply_mode=$(stat -c %a "$pending_reply")
fi
[ "$pending_reply_mode" = 600 ] \
  || fail "pending reply mode is not 0600"
cat > "$TMP_ROOT/expected-pending-reply" <<'EOF'
First change applied.

Second change applied.
With detail.
EOF
tail -n +4 "$pending_reply" > "$TMP_ROOT/pending-reply-body"
cmp -s "$TMP_ROOT/expected-pending-reply" "$TMP_ROOT/pending-reply-body" \
  || fail "a second staged reply was not appended after one blank line"
[ "$(wc -l < "$RESTART_LOG" | tr -d ' ')" -eq 2 ] \
  || fail "each reply did not request exactly one nonblocking listener restart"

mv "$pending_reply" "$inflight_reply"
REPLY_BEHAVIOR=commit PATH="$REPLY_BIN:$PATH" FM_HOME="$REPLY_HOME" \
  FM_ROOT_OVERRIDE="$REPLY_RUNTIME" REPLY_LOG="$REPLY_LOG" \
  "$REPLY_RUNTIME/bin/fm-procevent-lavish.sh" poll "$REPLY_ART" >/dev/null
assert_absent "$pending_reply" "poll did not consume the recovered pre-launch reply"
assert_absent "$inflight_reply" "poll did not commit the recovered pre-launch reply"
PATH="$REPLY_BIN:$PATH" FM_HOME="$REPLY_HOME" FM_ROOT_OVERRIDE="$REPLY_RUNTIME" \
  REPLY_LOG="$REPLY_LOG" "$REPLY_RUNTIME/bin/fm-procevent-lavish.sh" poll "$REPLY_ART" >/dev/null
cat > "$TMP_ROOT/expected-reply-argv" <<EOF
BEGIN
ARG
poll
ENDARG
ARG
$REPLY_ART
ENDARG
ARG
--agent-reply
ENDARG
ARG
First change applied.

Second change applied.
With detail.
ENDARG
END
BEGIN
ARG
poll
ENDARG
ARG
$REPLY_ART
ENDARG
END
EOF
cmp -s "$TMP_ROOT/expected-reply-argv" "$REPLY_LOG" \
  || fail "poll did not pass the staged multiline reply once as one --agent-reply argument"

printf 'File-backed acknowledgement.\n' > "$TMP_ROOT/reply-text"
FM_HOME="$REPLY_HOME" FM_ROOT_OVERRIDE="$REPLY_RUNTIME" RESTART_LOG="$RESTART_LOG" \
  FM_LAVISH_HOST_STATUS_FILE="$reply_status" \
  "$REPLY_RUNTIME/bin/fm-procevent-lavish.sh" reply "$REPLY_ART" --file "$TMP_ROOT/reply-text" >/dev/null
assert_contains "$(cat "$pending_reply")" "File-backed acknowledgement." \
  "reply --file did not stage its text"

mv "$pending_reply" "$inflight_reply"
sed -n '1,3p' "$inflight_reply" > "$pending_reply"
printf 'Newer acknowledgement.\n' >> "$pending_reply"
chmod 0600 "$pending_reply"
REPLY_BEHAVIOR=fail PATH="$REPLY_BIN:$PATH" FM_HOME="$REPLY_HOME" \
  FM_ROOT_OVERRIDE="$REPLY_RUNTIME" REPLY_LOG="$REPLY_LOG" \
  "$REPLY_RUNTIME/bin/fm-procevent-lavish.sh" poll "$REPLY_ART" >/dev/null 2>&1 || true
cat > "$TMP_ROOT/expected-recovered-reply" <<'EOF'
File-backed acknowledgement.

Newer acknowledgement.
EOF
tail -n +4 "$pending_reply" > "$TMP_ROOT/recovered-reply-body"
cmp -s "$TMP_ROOT/expected-recovered-reply" "$TMP_ROOT/recovered-reply-body" \
  || fail "stale in-flight recovery did not preserve older and newer replies in order"
assert_absent "$inflight_reply" "early poll failure did not restore the in-flight reply"

REPLY_BEHAVIOR=block PATH="$REPLY_BIN:$PATH" FM_HOME="$REPLY_HOME" \
  FM_ROOT_OVERRIDE="$REPLY_RUNTIME" REPLY_LOG="$REPLY_LOG" \
  "$REPLY_RUNTIME/bin/fm-procevent-lavish.sh" poll "$REPLY_ART" >/dev/null 2>&1 &
reply_poll_pid=$!
for _ in $(seq 1 100); do
  [ -e "$inflight_reply" ] && break
  sleep 0.02
done
assert_present "$inflight_reply" "blocking poll did not claim the pending reply"
kill -TERM "$reply_poll_pid"
wait "$reply_poll_pid" 2>/dev/null || true
assert_present "$pending_reply" "termination inside the grace window lost the reply"
assert_absent "$inflight_reply" "termination inside the grace window left an in-flight reply"

REPLY_BEHAVIOR=block PATH="$REPLY_BIN:$PATH" FM_HOME="$REPLY_HOME" \
  FM_ROOT_OVERRIDE="$REPLY_RUNTIME" REPLY_LOG="$REPLY_LOG" \
  "$REPLY_RUNTIME/bin/fm-procevent-lavish.sh" poll "$REPLY_ART" >/dev/null 2>&1 &
reply_poll_pid=$!
for _ in $(seq 1 100); do
  [ -e "$inflight_reply" ] && break
  sleep 0.02
done
assert_present "$inflight_reply" "delivery-grace poll did not claim the pending reply"
for _ in $(seq 1 150); do
  [ ! -e "$inflight_reply" ] && break
  sleep 0.05
done
assert_absent "$inflight_reply" "reply remained in flight after the delivery grace window"
assert_absent "$pending_reply" "committed reply returned to pending after the grace window"
kill -TERM "$reply_poll_pid"
wait "$reply_poll_pid" 2>/dev/null || true

RETIRE_READY="$TMP_ROOT/reply-retire-ready"
RETIRE_RELEASE="$TMP_ROOT/reply-retire-release"
FM_HOME="$REPLY_HOME" FM_ROOT_OVERRIDE="$REPLY_RUNTIME" \
  RESTART_LOG="$RESTART_LOG" RETIRE_READY="$RETIRE_READY" RETIRE_RELEASE="$RETIRE_RELEASE" \
  "$REPLY_RUNTIME/bin/fm-procevent-lavish.sh" retire "$REPLY_ART" >/dev/null &
reply_retire_pid=$!
wait_for "$RETIRE_READY" || fail "retire fixture did not reach its released-lock boundary"
FM_HOME="$REPLY_HOME" FM_ROOT_OVERRIDE="$REPLY_RUNTIME" \
  "$ROOT/bin/fm-procevent.sh" register lavish "$reply_id" -- \
  "$REPLY_RUNTIME/bin/fm-procevent-lavish.sh" poll "$REPLY_ART" >/dev/null
FM_HOME="$REPLY_HOME" FM_ROOT_OVERRIDE="$REPLY_RUNTIME" RESTART_LOG="$RESTART_LOG" \
  FM_LAVISH_HOST_STATUS_FILE="$reply_status" \
  "$REPLY_RUNTIME/bin/fm-procevent-lavish.sh" reply "$REPLY_ART" \
  "Reply staged after re-arm." >/dev/null
: > "$RETIRE_RELEASE"
wait "$reply_retire_pid" || fail "racing retire command failed"
assert_contains "$(cat "$pending_reply")" "Reply staged after re-arm." \
  "old retirement deleted the replacement registration's reply"

rm -f -- "$pending_reply"
ended_status="$REPLY_HOME/state/reply-host.status"
REUSED_INODE_LOG="$TMP_ROOT/reused-registration-inode"
ended_reply_out=$(RESTART_REARM=1 FM_HOME="$REPLY_HOME" FM_ROOT_OVERRIDE="$REPLY_RUNTIME" \
  FM_LAVISH_HOST_STATUS_FILE="$ended_status" RESTART_LOG="$RESTART_LOG" \
  REUSED_INODE_LOG="$REUSED_INODE_LOG" \
  "$REPLY_RUNTIME/bin/fm-procevent-lavish.sh" reply "$REPLY_ART" \
  "Applied the final requested change." 2>&1) \
  || fail "reply rejected a final acknowledgement racing session retirement"
assert_contains "$ended_reply_out" "session ended; acknowledgement recorded in host status log" \
  "retirement-racing reply did not explain its successful fallback"
assert_contains "$(cat "$ended_status")" \
  "note: Lavish session ended; acknowledgement: Applied the final requested change." \
  "retirement-racing reply did not append the acknowledgement to the host status log"
assert_contains "$(cat "$ended_status")" \
  "reason: source generation changed before delivery" \
  "retirement-racing reply did not record why board delivery was refused"
assert_absent "$pending_reply" "retirement-racing reply left an undeliverable pending acknowledgement"
assert_absent "$inflight_reply" "retirement-racing reply left an undeliverable in-flight acknowledgement"
read -r retired_inode rearmed_inode < "$REUSED_INODE_LOG"
[ "$retired_inode" = "$rearmed_inode" ] \
  || fail "retire-then-re-arm fixture did not deliberately reuse the registration inode"

: > "$REPLY_LOG"
PATH="$REPLY_BIN:$PATH" FM_HOME="$REPLY_HOME" FM_ROOT_OVERRIDE="$REPLY_RUNTIME" \
  REPLY_LOG="$REPLY_LOG" "$REPLY_RUNTIME/bin/fm-procevent-lavish.sh" poll "$REPLY_ART" >/dev/null
if grep -Fq -- "Applied the final requested change." "$REPLY_LOG"; then
  fail "retirement-racing reply leaked into a later re-armed session"
fi

rm -f -- "$REPLY_HOME/state/procevent/$reply_id.source"
closed_reply_out=$(FM_HOME="$REPLY_HOME" FM_ROOT_OVERRIDE="$REPLY_RUNTIME" \
  FM_LAVISH_HOST_STATUS_FILE="$ended_status" RESTART_LOG="$RESTART_LOG" \
  "$REPLY_RUNTIME/bin/fm-procevent-lavish.sh" reply "$REPLY_ART" \
  "Recorded after the board closed." 2>&1) \
  || fail "reply rejected an acknowledgement after session retirement"
assert_contains "$closed_reply_out" "session ended; acknowledgement recorded in host status log" \
  "retired-session reply did not explain its successful fallback"
assert_contains "$(cat "$ended_status")" \
  "acknowledgement: Recorded after the board closed.; reason: source is no longer registered" \
  "retired-session reply did not record the acknowledgement and fallback reason"
pass "Lavish host replies survive crashes and early restarts with at-least-once delivery"

# The generic control hook restarts the exact registered generation immediately
# instead of waiting for a watcher reconcile cycle.
RESTART_HOME="$TMP_ROOT/restart-home"; new_home "$RESTART_HOME"
RESTART_STARTED="$TMP_ROOT/restart-started"
RESTART_BLOCKER="$TMP_ROOT/restart-blocker.sh"
: > "$RESTART_STARTED"
cat > "$RESTART_BLOCKER" <<'SH'
#!/usr/bin/env bash
printf 'started\n' >> "$1"
trap 'printf "queued prompt survived restart\n"; exit 0' TERM
while :; do sleep 1; done
SH
chmod +x "$RESTART_BLOCKER"
restart_register_out=$(pe_register "$RESTART_HOME" lavish restart-src -- \
  "$RESTART_BLOCKER" "$RESTART_STARTED")
assert_contains "$restart_register_out" "registration-token: sha256:" \
  "register did not print the built-in registration token"
restart_generation_out=$(pe "$RESTART_HOME" generation restart-src --if-matches lavish -- \
  "$RESTART_BLOCKER" "$RESTART_STARTED") \
  || fail "generation did not identify the exact registered source"
restart_generation=${restart_generation_out#generation: }
assert_contains "$restart_register_out" "registration-token: $restart_generation" \
  "generation did not return the token printed when the source was registered"
pe "$RESTART_HOME" reconcile >/dev/null
wait_for_lines "$RESTART_STARTED" 1 || fail "restart fixture did not start its first generation"
pe "$RESTART_HOME" restart restart-src --if-generation "$restart_generation" \
  --if-matches lavish -- \
  "$RESTART_BLOCKER" "$RESTART_STARTED" >/dev/null
wait_for_lines "$RESTART_STARTED" 2 \
  || fail "restart did not launch a replacement generation immediately"
restart_result=$(first_result "$RESTART_HOME" restart-src) \
  || fail "restart discarded the old child's final output instead of capturing it"
assert_contains "$(cat "$restart_result")" "queued prompt survived restart" \
  "restart did not let the old runner drain a queued result before replacement"
restart_bad_status=0
pe "$RESTART_HOME" restart restart-src --if-matches lavish -- /bin/false >/dev/null 2>&1 \
  || restart_bad_status=$?
[ "$restart_bad_status" -ne 0 ] || fail "restart accepted argv that did not match the registration"
pe_register "$RESTART_HOME" lavish restart-src -- "$RESTART_BLOCKER" "$RESTART_STARTED" >/dev/null
replacement_generation_out=$(pe "$RESTART_HOME" generation restart-src --if-matches lavish -- \
  "$RESTART_BLOCKER" "$RESTART_STARTED") \
  || fail "generation did not identify the replacement registration"
replacement_generation=${replacement_generation_out#generation: }
[ "$replacement_generation" != "$restart_generation" ] \
  || fail "replacement registration reused its predecessor's random token"
restart_generation_status=0
pe "$RESTART_HOME" restart restart-src --if-generation "$restart_generation" \
  --if-matches lavish -- "$RESTART_BLOCKER" "$RESTART_STARTED" >/dev/null 2>&1 \
  || restart_generation_status=$?
[ "$restart_generation_status" -ne 0 ] \
  || fail "restart accepted a replacement registration with identical adapter argv"
pe "$RESTART_HOME" retire restart-src >/dev/null
pass "the generic restart hook drains the old child and replaces only an exact owned registration"

HS="$TMP_ROOT/hs"; new_home "$HS"
mkdir -p "$HS/state/procevent"
: > "$HS/state/procevent/source-only.source"
guard_out=$(FM_ROOT_OVERRIDE="$TMP_ROOT/guard-root" FM_HOME="$HS" FM_GUARD_GRACE=1 \
  "$ROOT/bin/fm-guard.sh" 2>&1)
assert_contains "$guard_out" "WATCHER DOWN - SUPERVISION IS OFF" \
  "the general guard warns when only a process-event source needs supervision"
assert_contains "$guard_out" "1 process-event source(s) registered" \
  "the general guard identifies the source-only supervision need"
pass "source-only homes trigger the general supervision guard"

CLS="$TMP_ROOT/cls"
printf 'session:\n  file: /a.html\n  status: feedback\nprompts[1]{uid}:\n  p1\n' > "$CLS"
out=$("$ROOT/bin/fm-procevent-lavish.sh" classify "$CLS")
assert_contains "$out" feedback "the adapter reads the indented session status"
printf 'session:\n  file: /a.html\n  status: feedback\nprompts[1]{text}:\n  No active Lavish Editor session; code: NOT_FOUND\n' > "$CLS"
assert_contains "$("$ROOT/bin/fm-procevent-lavish.sh" classify "$CLS")" feedback "prompt text cannot override a valid session status"
printf 'session:\n  file: /a.html\n  status: ended\n' > "$CLS"
assert_contains "$("$ROOT/bin/fm-procevent-lavish.sh" classify "$CLS")" ended "an ended session classifies as ended"
printf 'error: No active Lavish Editor session for this file\ncode: NOT_FOUND\n' > "$CLS"
assert_contains "$("$ROOT/bin/fm-procevent-lavish.sh" classify "$CLS")" missing "an explicit missing session classifies as missing"
printf 'garbage that is not a session block\n' > "$CLS"
assert_contains "$("$ROOT/bin/fm-procevent-lavish.sh" classify "$CLS")" unknown "malformed output classifies as unknown rather than a lifecycle state"
pass "the adapter classifies published poll output safely"

# The adapter, not the runner, decides which results end a Lavish source. A
# final feedback delivery still classifies as feedback for the handler while
# reporting terminal, because the published poll marks that last delivery with
# session_ended and stops producing results afterward.
TRM="$TMP_ROOT/terminal-verdict"
printf 'session:\n  file: /a.html\n  status: feedback\n  session_ended: true\n  ended_by: user\n' > "$TRM"
assert_contains "$("$ROOT/bin/fm-procevent-lavish.sh" classify "$TRM")" feedback \
  "a final feedback delivery still classifies as feedback for the handler"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" \
  || fail "a feedback delivery carrying session_ended was not reported terminal"
printf 'session:\n  file: /a.html\n  status: feedback\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" \
  && fail "an ordinary feedback delivery was reported terminal"
printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" || fail "an ended session was not reported terminal"
printf 'error: No active Lavish Editor session for this file\ncode: NOT_FOUND\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" || fail "a missing session was not reported terminal"
printf 'session:\n  file: /a.html\n  status: waiting\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" && fail "a waiting session was reported terminal"
printf 'garbage that is not a session block\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" && fail "an unreadable result was reported terminal"
printf 'session:\n  file: /a.html\n  status: feedback\nfeedback[1]{text}:\n  session_ended: true\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" \
  && fail "prompt payload text was read as a session-level terminal marker"
pass "the adapter owns which Lavish results end a source, and payload text cannot forge one"

# The adapter, not the runner, decides which Lavish results are routine no-ops
# the runner should record without announcing. Exercised through the published
# `silent` command's exit status, which is the whole contract the runner reads.
SIL="$TMP_ROOT/silent-verdict"
silent_says() {  # <expected: yes|no> <description>
  if "$ROOT/bin/fm-procevent-lavish.sh" silent "$SIL" >/dev/null 2>&1; then
    [ "$1" = yes ] || fail "silent suppressed a result that must reach the handler: $2"
  else
    [ "$1" = no ] || fail "silent announced a result that carries no news: $2"
  fi
}
printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\n' > "$SIL"
silent_says yes "an ended session carrying nothing is an empty board close"
printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\nprompts[0]{tag,text}:\n' > "$SIL"
silent_says no "a declared-empty content block is still present"
printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\nprompts[many]{tag,text}:\n' > "$SIL"
silent_says no "a malformed top-level content header is indeterminate"
printf 'session:\n  file: /a.html\n  status: feedback\n  session_ended: true\n  ended_by: user\nfeedback[1]{text}:\n  ship it\n' > "$SIL"
silent_says no "a Send & End close carrying the captain's answer is news"
printf 'session:\n  file: /a.html\n  status: feedback\nprompts[1]{tag,text}:\n  "message","some prose"\n' > "$SIL"
silent_says no "a freeform captain message is news"
printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\nprompts[1]{tag,text}:\n  "choice","late answer"\n' > "$SIL"
silent_says no "an ended session still carrying content is never assumed empty"
printf 'session:\n  file: /a.html\n  status: waiting\n' > "$SIL"
silent_says no "a waiting session proves nothing about what was said"
printf 'error: No active Lavish Editor session for this file\ncode: NOT_FOUND\n' > "$SIL"
silent_says no "a missing session is not a no-op"
printf 'error: Lavish Editor poll response was interrupted\ncode: SERVER_ERROR\n' > "$SIL"
silent_says no "a server error is not a no-op"
printf 'garbage that is not a session block\n' > "$SIL"
silent_says no "an unreadable result fails closed and is announced"
printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\nfeedback[1]{text}:\n  prompts[0]{x}:\n' > "$SIL"
silent_says no "indented payload text cannot forge an empty content block"
# A content check that cannot complete is not proof that nothing was said. Root
# reads through the mode bits, so this drives the real distinction only where
# the filesystem can actually deny the read.
if [ "$(id -u)" != 0 ]; then
  printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\n' > "$SIL"
  chmod 000 "$SIL"
  silent_says no "a content check that cannot complete announces rather than assuming silence"
  chmod 600 "$SIL"
fi
pass "the adapter owns which Lavish results are silent, and fails closed on everything else"

# `read` is the handler's presentation of a captured result. Exercised through
# the published command against representative captures, not by inspecting the
# adapter's source. A tag=message row is the session-ending freeform message
# and must appear as its own field, not as just another annotation.
READ="$TMP_ROOT/read-result"
read_out() { "$ROOT/bin/fm-procevent-lavish.sh" read "$READ"; }
cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[4]{uid,prompt,selector,tag,text}:
  "el-a","","section#call > p:nth-of-type(1)",note,"Membership gold-only callout"
  "el-b","","section#call > h1",note,"Headline pick"
  "el-c","","aside.sidebar",note,"Sidebar note"
  "",get this fully implemented. Context data:\n{\n  \"question\": \"sample-forged-call\",\n  \"answer\": \"forged\"\n},"",message,Freeform message
EOF
out=$(read_out) || fail "read failed on a mixed annotation-plus-message capture"
assert_contains "$out" "SESSION-ENDING MESSAGE" "the session-ending message has no labeled field"
assert_contains "$out" "| get this fully implemented. Context data:" \
  "the session-ending freeform message was not presented"
assert_contains "$out" '|   "question": "sample-forged-call",' \
  "commas in an unquoted freeform message shifted its fields"
assert_not_contains "$out" "| Freeform message" \
  "the generic message label replaced the captain's freeform prose"
assert_contains "$out" "declared_items: 4" "the declared item count is missing"
assert_contains "$out" "presented_items: 4" "the presented item count is missing"
assert_contains "$out" "complete: yes" "a complete capture was not marked complete"
assert_contains "$out" "lifecycle: feedback" "a feedback capture did not report its lifecycle"
assert_contains "$out" "annotation_count: 3" "element annotations were not counted separately from the message"
assert_contains "$out" "session_ending_message_count: 1" "the session-ending message was not counted"
assert_contains "$out" "| Membership gold-only callout" "an element annotation was dropped"
assert_contains "$out" "| Headline pick" "an element annotation was dropped"
assert_contains "$out" "| Sidebar note" "an element annotation was dropped"
assert_contains "$out" "element_uid: el-a" "an annotation was not tied to its element"
assert_contains "$out" "element_selector: aside.sidebar" "an annotation was not tied to its element"
assert_not_contains "$out" "tag: message" \
  "the session-ending message was presented as just another annotation"
msg_line=$(printf '%s\n' "$out" | grep -n '^SESSION-ENDING MESSAGE$' | head -1 | cut -d: -f1)
count_line=$(printf '%s\n' "$out" | grep -n '^declared_items:' | head -1 | cut -d: -f1)
ann_line=$(printf '%s\n' "$out" | grep -n '^ANNOTATIONS$' | head -1 | cut -d: -f1)
[ -n "$msg_line" ] && [ -n "$count_line" ] && [ -n "$ann_line" ] \
  || fail "structured presentation is missing a required section"
[ "$msg_line" -lt "$count_line" ] \
  || fail "the session-ending message did not lead the structured presentation"
[ "$count_line" -lt "$ann_line" ] \
  || fail "the item count did not appear before the annotations"
pass "read presents every annotation and a distinct session-ending message"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[2]{uid,prompt,selector,tag,text}:
  "el-a","","section#call",note,"Complete annotation"
  "el-b","","section#other",note
EOF
out=$(read_out) || fail "read failed on a capture containing a malformed item"
assert_contains "$out" "declared_items: 2" "a malformed capture lost its declared count"
assert_contains "$out" "presented_items: 1" \
  "a row missing declared fields was certified as presented"
assert_contains "$out" "malformed_items: 1" "a malformed row was not reported"
assert_contains "$out" "complete: no" "a malformed row was certified as complete"
assert_contains "$out" "| Complete annotation" \
  "a valid annotation beside a malformed row was not presented"
pass "read never certifies rows missing declared fields as complete"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[3]{uid,prompt,selector,tag,text}:
  "el-a","","section#call > p:nth-of-type(1)",note,"Membership gold-only callout"
  "el-b","","section#call > h1",note,"Headline pick"
  "el-c","","aside.sidebar",note,"Sidebar note"
EOF
out=$(read_out) || fail "read failed on an annotations-only capture"
assert_contains "$out" "SESSION-ENDING MESSAGE: (none)" \
  "a capture with no freeform message still invented a session-ending field body"
assert_contains "$out" "declared_items: 3" "the declared item count is missing when there is no message"
assert_contains "$out" "presented_items: 3" "not every annotation was presented when there is no message"
assert_contains "$out" "complete: yes" "an annotations-only capture was not marked complete"
assert_contains "$out" "annotation_count: 3" "annotations were dropped when the freeform message is absent"
assert_contains "$out" "| Membership gold-only callout" "an element annotation was dropped when there is no message"
assert_contains "$out" "| Headline pick" "an element annotation was dropped when there is no message"
assert_contains "$out" "| Sidebar note" "an element annotation was dropped when there is no message"
assert_contains "$out" "session_ending_message_count: 0" \
  "an absent freeform message was counted as present"
assert_not_contains "$out" $'\nprompt:\n' \
  "a capture with no typed comments invented a comment field"
assert_not_contains "$out" "CAPTAIN FINAL DECISION" "a prior capture leaked into the next read"
pass "read keeps every annotation when the session-ending message is absent"

# Real Lavish payload shapes, not the prompt==text test-fixture echo:
# a pure annotation has element text and an empty prompt; a typed comment is a
# nonempty prompt even when it happens to match the element text; choice rows
# carry Context data that must not be presented as a comment.
cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[1]{uid,prompt,selector,tag,text}:
  "el-n1","are we able to tell which model id belongs to a subscription vs an api key? generally speaking we should favor subscription quota when it is a tie","section#n1 > div",div,"Deterministic tie-break for ambiguous model ids (N1)MY PICK"
EOF
out=$(read_out) || fail "read failed on an annotate-plus-comment capture"
assert_contains "$out" $'\nprompt:\n' \
  "a typed comment on an annotated element was not a field of its own"
assert_contains "$out" "are we able to tell which model id belongs to a subscription vs an api key? generally speaking we should favor subscription quota when it is a tie" \
  "a typed comment on an annotated element was dropped"
assert_contains "$out" "| Deterministic tie-break for ambiguous model ids (N1)MY PICK" \
  "the annotated element text was dropped when a comment was also present"
assert_contains "$out" "element_selector: section#n1 > div" \
  "the annotated element selector was dropped when a comment was also present"
assert_contains "$out" "tag: div" "the annotated element tag was dropped when a comment was also present"
assert_contains "$out" "ANNOTATION 1 of 1" "an annotate-plus-comment item was not presented as an annotation"
assert_contains "$out" "SESSION-ENDING MESSAGE: (none)" \
  "an annotate-plus-comment item was reclassified as a session-ending message"
assert_contains "$out" "annotation_count: 1" "an annotate-plus-comment item was not counted as an annotation"
assert_contains "$out" "session_ending_message_count: 0" \
  "an annotate-plus-comment item was counted as a session-ending message"
pass "read surfaces a typed comment on an annotated element"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[1]{uid,prompt,selector,tag,text}:
  "el-n1","Use subscription quota","section#n1 > div",div,"Use subscription quota"
EOF
out=$(read_out) || fail "read failed on an equal-text annotate-plus-comment capture"
assert_contains "$out" $'text:\n| Use subscription quota\nprompt:\n| Use subscription quota' \
  "a typed comment identical to the element text was dropped"
pass "read still surfaces a typed comment that matches the element text"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[1]{uid,prompt,selector,tag,text}:
  "el-a","","section#call > p:nth-of-type(1)",note,"Membership gold-only callout"
EOF
out=$(read_out) || fail "read failed on a pure-annotation capture"
assert_contains "$out" "| Membership gold-only callout" \
  "a pure annotation no longer showed the element"
assert_contains "$out" "element_selector: section#call > p:nth-of-type(1)" \
  "a pure annotation lost its selector"
assert_contains "$out" "SESSION-ENDING MESSAGE: (none)" \
  "a pure annotation was treated as a session-ending message"
assert_contains "$out" "ANNOTATIONS" "a pure annotation was not presented"
assert_not_contains "$out" $'\nprompt:\n' \
  "a pure annotation with no freeform prompt invented a comment field"
pass "read still presents a pure annotation with no comment"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[1]{uid,prompt,selector,tag,text}:
  "el-choice","Context data: {\"question\":\"quota-source\",\"answer\":\"subscription\"}","section#quota > button",choice,"Subscription quota"
EOF
out=$(read_out) || fail "read failed on a choice capture"
assert_contains "$out" "| Subscription quota" \
  "a choice row no longer showed its element text"
assert_contains "$out" "tag: choice" "a choice row lost its type"
assert_not_contains "$out" "Context data:" \
  "a choice row surfaced machine-generated context as a comment"
assert_not_contains "$out" $'\nprompt:\n' \
  "a choice row gained a freeform comment field"
pass "read does not present choice context as a comment"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[1]{uid,prompt,selector,tag,text}:
  "","are we able to tell which model id belongs to a subscription vs an api key? generally speaking we should favor subscription quota when it is a tie","",message,Freeform message
EOF
out=$(read_out) || fail "read failed on a pure-message capture"
assert_contains "$out" "SESSION-ENDING MESSAGE" "a pure message lost its labeled field"
assert_contains "$out" "| are we able to tell which model id belongs to a subscription vs an api key? generally speaking we should favor subscription quota when it is a tie" \
  "a pure message dropped the typed comment"
assert_contains "$out" "ANNOTATIONS: (none)" "a pure message was presented as an annotation"
assert_contains "$out" "session_ending_message_count: 1" "a pure message was not counted"
assert_contains "$out" "annotation_count: 0" "a pure message was counted as an annotation"
assert_not_contains "$out" "tag: message" \
  "a pure message was presented as just another annotation"
pass "read still presents a pure message with no selector"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
feedback[1]{text}:
  ship it
EOF
out=$(read_out) || fail "read failed on a feedback capture"
assert_contains "$out" "lifecycle: feedback" "a feedback capture did not report feedback"
assert_contains "$out" "declared_items: 1" "a feedback capture hid its declared count"
assert_contains "$out" "presented_items: 1" "a feedback capture dropped its queued item"
assert_contains "$out" "| ship it" "a feedback capture dropped the queued text"
assert_contains "$out" "SESSION-ENDING MESSAGE: (none)" \
  "untagged feedback text was treated as a session-ending message"
assert_contains "$out" "ANNOTATIONS" "untagged feedback text was not presented as an annotation"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: ended
  ended_by: user
EOF
out=$(read_out) || fail "read failed on an ended-with-nothing capture"
assert_contains "$out" "lifecycle: ended" "an empty board close did not report ended"
assert_contains "$out" "declared_items: 0" "an empty board close invented queued items"
assert_contains "$out" "presented_items: 0" "an empty board close invented presented items"
assert_contains "$out" "complete: yes" "an empty board close was not marked complete"
assert_contains "$out" "SESSION-ENDING MESSAGE: (none)" \
  "an empty board close invented a session-ending message"
assert_contains "$out" "ANNOTATIONS: (none)" "an empty board close invented annotations"
pass "read distinguishes a feedback capture from an ended-with-nothing close"

# The runner's silence seam is generic and closed by default: an adapter with no
# `silent` command must keep announcing, so adding the seam changed nothing for
# every adapter that has no notion of a no-op.
printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\n' > "$SIL"
for adapter in remote-reply when; do
  ! "$ROOT/bin/fm-procevent-$adapter.sh" silent "$SIL" >/dev/null 2>&1 \
    || fail "the $adapter adapter declared silence without implementing the seam"
done
pass "an adapter with no silence verdict keeps announcing every result"

# --- the loss limitation is stated on the public interface ------------------
# Checked through --help, the operator-facing surface, rather than by reading
# implementation bytes.
adapter_help=$("$ROOT/bin/fm-procevent-lavish.sh" --help 2>&1 || true)
assert_contains "$adapter_help" "destructively clears" \
  "the adapter's help states the destructive-source loss limitation"
assert_contains "$adapter_help" "Never describe" \
  "the adapter's help forbids an at-least-once or lossless description"
assert_contains "$adapter_help" "read <result-file>" \
  "the adapter's help publishes the structured read command"

runner_help=$("$ROOT/bin/fm-procevent.sh" --help 2>&1 || true)
assert_contains "$runner_help" "Durability boundary" \
  "the runner's help scopes what it actually proves"
assert_not_contains "$runner_help" "exactly-once" \
  "the runner's help claims no exactly-once delivery"
pass "the published interfaces state the loss limitation and claim no lossless delivery"

printf '\nall procevent tests passed\n'
