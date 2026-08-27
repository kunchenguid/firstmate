#!/usr/bin/env bash
# Gate g-boot-digest: boot-time reconciliation digest in the captain context block.
#
# fm-captain-bootstrap.sh (SessionStart hook) must append a read-only
# "## Reconciliation digest (boot-time snapshot)" section to the captain context:
# wake-queue depth + up to 5 most recent records (lock-free read, torn-tail rule),
# watcher health relayed verbatim from `fm-watch-arm.sh --status`, session lock
# relayed verbatim from `fm-lock.sh status`, in-flight task metas with last status
# line, the .afk flag, and the exact snapshot disclaimer. The digest is a snapshot,
# not reconciliation: it must never drain the queue or touch markers/locks.
#
# Stub seam: the bootstrap resolves helper scripts through its own bin dir,
# overridable via FM_BOOTSTRAP_BIN — that is the seam this test stubs for the
# relay assertions (watcher/lock lines are relays, proven verbatim; canonical
# liveness semantics stay the helpers' job).
#
# Also proves `fm-watch-arm.sh --status` against the real repo bin: one stdout
# line, exit 0, pinned grammar in the three constructible states, and
# side-effect-free (no watcher started/killed, lock+beacon files untouched).
#
# Mutation (LEDGER_MUTATE=1): the wake-queue fixture records are not written, so
# the queue-depth assertion fails.
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

BOOT="$ROOT/bin/fm-captain-bootstrap.sh"
WATCHARM="$ROOT/bin/fm-watch-arm.sh"
DISCLAIMER='Snapshot as of boot — run bin/fm-wake-drain.sh before acting on the fleet.'

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-boot-digest.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

path_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1"; else stat -c %Y "$1"; fi
}

run_boot() {  # $1 = FM home; role/seam come from caller env
  printf '%s' '{"source":"startup","cwd":"/tmp/x","session_id":"sess-digest"}' \
    | FM_HOME="$1" FM_CTX_WINDOW=digesttest "$BOOT"
}

ctx_of() {  # stdin: hook JSON -> additionalContext text (fails on invalid JSON)
  python3 -c 'import json,sys; print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"])'
}

# --- Case A: populated fixture, stubbed helpers -> full digest ----------------
FM="$TMP/homeA"
mkdir -p "$FM/data" "$FM/state"
printf 'demo [no-mistakes] - a demo project\n' > "$FM/data/projects.md"
: > "$FM/data/secondmates.md"
printf -- '- a backlog item\n' > "$FM/data/backlog.md"
if [ "${LEDGER_MUTATE:-}" != 1 ]; then
  {
    printf '1751900001\t1\tsignal\ttask-a\tdone: PR ready\n'
    printf '1751900002\t2\theartbeat\t-\t-\n'
    printf '1751900003\t3\tstale\ttask-b\tpane quiet\n'
  } >> "$FM/state/.wake-queue"
fi
printf 'window=fm-task-a\nworktree=/tmp/wt-a\nproject=demo\nharness=claude\nkind=ship\nmode=no-mistakes\nyolo=off\n' \
  > "$FM/state/task-a.meta"
printf 'working: setup done\nworking: STATUS-TAIL-A fix implemented\n' > "$FM/state/task-a.status"
printf 'window=fm-task-b\nkind=scout\nmode=direct-PR\n' > "$FM/state/task-b.meta"
touch "$FM/state/.afk"

STUB="$TMP/stub-bin"
mkdir -p "$STUB"
printf '#!/usr/bin/env bash\necho "lock: STUB-LOCK-RELAY-7f3"\n' > "$STUB/fm-lock.sh"
printf '#!/usr/bin/env bash\necho "watcher-status: STUB-WATCH-RELAY-9c1"\n' > "$STUB/fm-watch-arm.sh"
chmod +x "$STUB/fm-lock.sh" "$STUB/fm-watch-arm.sh"

queue_before=$(cat "$FM/state/.wake-queue" 2>/dev/null || true)
out=$(FIRSTMATE_ROLE=captain FM_BOOTSTRAP_BIN="$STUB" run_boot "$FM") || fail "case A: bootstrap must exit 0"
ctx=$(printf '%s' "$out" | ctx_of) || fail "case A: output must be valid hook JSON"

printf '%s' "$ctx" | grep -q '^## Reconciliation digest (boot-time snapshot)$' \
  || fail "case A: digest section header missing"
printf '%s' "$ctx" | grep -q 'Wake queue: 3 queued' \
  || fail "case A: queue depth must be 3 (got: $(printf '%s' "$ctx" | grep 'Wake queue' || echo none))"
printf '%s' "$ctx" | grep -qF "$(printf '1751900001\t1\tsignal\ttask-a\tdone: PR ready')" \
  || fail "case A: record 1 must appear verbatim"
printf '%s' "$ctx" | grep -qF "$(printf '1751900002\t2\theartbeat\t-\t-')" \
  || fail "case A: record 2 must appear verbatim"
printf '%s' "$ctx" | grep -qF "$(printf '1751900003\t3\tstale\ttask-b\tpane quiet')" \
  || fail "case A: record 3 must appear verbatim"
printf '%s' "$ctx" | grep -q 'task-a .*window=fm-task-a.*kind=ship.*mode=no-mistakes' \
  || fail "case A: task-a meta line missing"
printf '%s' "$ctx" | grep -q 'working: STATUS-TAIL-A fix implemented' \
  || fail "case A: task-a last status line missing"
printf '%s' "$ctx" | grep -q 'task-b .*window=fm-task-b.*kind=scout.*mode=direct-PR' \
  || fail "case A: task-b meta line missing"
printf '%s' "$ctx" | grep -q 'task-b .*(no status yet)' \
  || fail "case A: task-b must report (no status yet)"
printf '%s' "$ctx" | grep -qF 'watcher-status: STUB-WATCH-RELAY-9c1' \
  || fail "case A: watcher line must be relayed verbatim from fm-watch-arm.sh --status"
printf '%s' "$ctx" | grep -qF 'lock: STUB-LOCK-RELAY-7f3' \
  || fail "case A: lock line must be relayed verbatim from fm-lock.sh status"
printf '%s' "$ctx" | grep -q 'afk: yes' || fail "case A: afk flag must be reported"
printf '%s' "$ctx" | grep -qF "$DISCLAIMER" || fail "case A: exact snapshot disclaimer missing"
printf '%s' "$ctx" | grep -q 'You are Cortana' || fail "case A: captain context must be preserved"

# Read-only: the digest must not drain, archive, or rewrite the queue.
queue_after=$(cat "$FM/state/.wake-queue" 2>/dev/null || true)
[ "$queue_before" = "$queue_after" ] || fail "case A: wake queue must be untouched by the digest"
[ -e "$FM/state/.wake-queue.lock" ] && fail "case A: digest must never create .wake-queue.lock"

# --- Case A2: torn tail excluded from depth+display, flagged ------------------
printf '1751900004\t4\tsignal' >> "$FM/state/.wake-queue"   # no newline, <5 fields
out=$(FIRSTMATE_ROLE=captain FM_BOOTSTRAP_BIN="$STUB" run_boot "$FM") || fail "case A2: bootstrap must exit 0"
ctx=$(printf '%s' "$out" | ctx_of) || fail "case A2: output must be valid hook JSON"
printf '%s' "$ctx" | grep -q 'Wake queue: 3 queued' \
  || fail "case A2: torn tail must be excluded from depth"
printf '%s' "$ctx" | grep -qF '(tail possibly torn)' || fail "case A2: torn-tail marker missing"
printf '%s' "$ctx" | grep -q '1751900004' && fail "case A2: torn record must not be displayed"

pass "A: digest carries queue, tasks, verbatim relays, afk, disclaimer; torn tail handled"

# --- Case B: empty state dir, real helpers -> graceful degrade ----------------
FMB="$TMP/homeB"
mkdir -p "$FMB/data" "$FMB/state"
out=$(FIRSTMATE_ROLE=captain run_boot "$FMB") || fail "case B: bootstrap must exit 0"
ctx=$(printf '%s' "$out" | ctx_of) || fail "case B: output must be valid hook JSON"
printf '%s' "$ctx" | grep -q 'Wake queue: empty' || fail "case B: empty queue must read empty"
printf '%s' "$ctx" | grep -qF 'watcher-status: none' \
  || fail "case B: real fm-watch-arm.sh --status must report none for a bare home"
printf '%s' "$ctx" | grep -qF 'lock: free' \
  || fail "case B: real fm-lock.sh status must report free for a bare home"
printf '%s' "$ctx" | grep -q 'afk: no' || fail "case B: afk must be no"
printf '%s' "$ctx" | grep -qF "$DISCLAIMER" || fail "case B: disclaimer must survive degradation"
pass "B: empty state dir degrades gracefully with valid hook JSON"

# --- Case C: overflow fixture -> capped with explicit truncation marker -------
FMC="$TMP/homeC"
mkdir -p "$FMC/data" "$FMC/state"
long=$(printf 'x%.0s' $(seq 1 400))
for i in 1 2 3 4 5 6 7 8; do
  printf '175190000%s\t%s\tsignal\ttask-%s\t%s\n' "$i" "$i" "$i" "$long" >> "$FMC/state/.wake-queue"
done
for i in $(seq 1 40); do
  printf 'window=fm-bulk-%s\nkind=ship\nmode=no-mistakes\n' "$i" > "$FMC/state/bulk-task-$i.meta"
  printf 'working: long status line %s %s\n' "$i" "$long" > "$FMC/state/bulk-task-$i.status"
done
out=$(FIRSTMATE_ROLE=captain FM_BOOTSTRAP_BIN="$STUB" run_boot "$FMC") || fail "case C: bootstrap must exit 0"
ctx=$(printf '%s' "$out" | ctx_of) || fail "case C: output must be valid hook JSON"
dig=$(printf '%s' "$ctx" | python3 -c 'import sys
t = sys.stdin.read()
i = t.find("## Reconciliation digest")
sys.stdout.write(t[i:] if i >= 0 else "")')
[ -n "$dig" ] || fail "case C: digest section missing"
dlen=$(printf '%s' "$dig" | python3 -c 'import sys; print(len(sys.stdin.read()))')
[ "$dlen" -le 2000 ] || fail "case C: digest must be capped at ~2000 chars (got $dlen)"
printf '%s' "$dig" | grep -q 'more)' || fail "case C: explicit truncation marker missing"
printf '%s' "$dig" | grep -qF "$DISCLAIMER" || fail "case C: disclaimer must survive the cap"
pass "C: overflow digest capped at ~2000 chars with explicit +N-more marker"

# --- Case D: non-captain role -> no digest, no output (unchanged) -------------
outD=$(FIRSTMATE_ROLE=crew run_boot "$FMB") || fail "case D: bootstrap must exit 0"
[ -z "$outD" ] || fail "case D: crew pane with no handoff must emit nothing (got: $outD)"
pass "D: non-captain role emits no digest"

# --- Case E: real fm-watch-arm.sh --status grammar + side-effect freedom ------
one_line_grammar() {  # $1 = line, $2 = case label
  case "$1" in
    *$'\n'*) fail "$2: --status must print exactly one line" ;;
  esac
  printf '%s' "$1" | grep -Eq \
    '^watcher-status: (healthy pid=[0-9]+ beacon-age=[0-9]+s|stale pid=([0-9]+|none) beacon-age=([0-9]+|none)|none)$' \
    || fail "$2: --status line violates pinned grammar (got: $1)"
}

# E1: none — no lock, no beacon.
H1="$TMP/wsA"
mkdir -p "$H1/state"
line=$(FM_HOME="$H1" "$WATCHARM" --status) || fail "E1: --status must exit 0"
one_line_grammar "$line" "E1"
[ "$line" = "watcher-status: none" ] || fail "E1: expected none state (got: $line)"

# E2: healthy — fake lock pointing at this live test shell, fresh beacon.
H2="$TMP/wsB"
S2="$H2/state"
mkdir -p "$S2"
OWNER="$S2/.watch.lock.owner.fixture"
mkdir -p "$OWNER"
echo $$ > "$OWNER/pid"
printf '%s\n' "$H2" > "$OWNER/fm-home"
printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$OWNER/watcher-path"
ps -p $$ -o lstart= -o command= | sed 's/^[[:space:]]*//' > "$OWNER/pid-identity"
ln -s "$OWNER" "$S2/.watch.lock"
touch "$S2/.last-watcher-beat"
pid_before=$(cat "$S2/.watch.lock/pid")
beat_mt_before=$(path_mtime "$S2/.last-watcher-beat")
lock_mt_before=$(path_mtime "$OWNER/pid")
line=$(FM_HOME="$H2" "$WATCHARM" --status) || fail "E2: --status must exit 0"
one_line_grammar "$line" "E2"
printf '%s' "$line" | grep -Eq "^watcher-status: healthy pid=$$ beacon-age=[0-9]+s$" \
  || fail "E2: expected healthy state for live pid + fresh beacon (got: $line)"
# Side-effect-free: lock and beacon files untouched, no watcher started.
[ "$(cat "$S2/.watch.lock/pid")" = "$pid_before" ] || fail "E2: lock pid file changed"
[ "$(path_mtime "$S2/.last-watcher-beat")" = "$beat_mt_before" ] || fail "E2: beacon mtime changed"
[ "$(path_mtime "$OWNER/pid")" = "$lock_mt_before" ] || fail "E2: lock pid mtime changed"
ls "$S2"/.watch-arm-output.* >/dev/null 2>&1 && fail "E2: --status must not fork a watcher child"

# E3: stale — same live-pid lock, but the beacon aged past FM_GUARD_GRACE.
line=$(FM_HOME="$H2" FM_GUARD_GRACE=1 sh -c 'sleep 2; exec "$0" --status' "$WATCHARM") \
  || fail "E3: --status must exit 0"
one_line_grammar "$line" "E3"
printf '%s' "$line" | grep -Eq "^watcher-status: stale pid=$$ beacon-age=[0-9]+$" \
  || fail "E3: expected stale state for aged beacon (got: $line)"
[ "$(cat "$S2/.watch.lock/pid")" = "$pid_before" ] || fail "E3: lock pid file changed"
ls "$S2"/.watch-arm-output.* >/dev/null 2>&1 && fail "E3: --status must not fork a watcher child"

pass "E: fm-watch-arm.sh --status honors pinned grammar in all three states, side-effect-free"

pass "g-boot-digest: boot-time reconciliation digest behaves as pinned"
