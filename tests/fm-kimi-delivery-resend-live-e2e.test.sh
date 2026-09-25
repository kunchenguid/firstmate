#!/usr/bin/env bash
# Live Kimi delivery-resend guard (live-harness-optin family).
#
# Kimi's startup input-swallow window can outlive the whole submit retry
# budget (reproduced on 2.0.2 and 2.1.1: readiness passed, the pointer sat in
# the composer, every Enter inside the budget was dropped). fm-spawn.sh's kimi
# delivery wait re-sends Enter while the composer provably still holds the
# pointer, and a failed delivery rolls its provisional record back so the
# backlog row stays queued. A stub cannot prove any of that against the real
# harness: Kimi 2.1.1 also moved its footer up against the composer box, which the shared
# composer classifier read as unclaimed activity (unknown) until it learned
# the footer as furniture. This guard launches real Kimi in an isolated Herdr
# lab and requires all of it, failing with the harness and version named
# rather than degrading quietly.
#
# Run explicitly with FM_KIMI_DELIVERY_RESEND_LIVE=1 after a Kimi or Herdr
# upgrade, and before trusting a refreshed docs/verification/runtime-backends.md
# "Kimi delivery" entry.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_KIMI_DELIVERY_RESEND_LIVE herdr jq kimi treehouse git

[ -x "$LAB_HELPER" ] || fail "FM_KIMI_DELIVERY_RESEND_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name kimi-delivery-resend-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-kimi-delivery-resend-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
SPAWN_HOME="$TMP_ROOT/home"
mkdir -p "$FAKEBIN" "$SPAWN_HOME/data" "$SPAWN_HOME/state" "$SPAWN_HOME/config" "$SPAWN_HOME/projects"
CHECKED=0
WORKTREES=()

cleanup() {
  local rc=$? wt
  trap - EXIT
  for wt in ${WORKTREES[@]+"${WORKTREES[@]}"}; do
    [ -n "$wt" ] && env PATH="$ORIGINAL_PATH" treehouse return --force "$wt" >/dev/null 2>&1
  done
  if ! env PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

# Keep the lab helper as the only CLI transport. Adapter calls have already
# appended the exact session; this shim strips that pair, refuses every other
# caller-supplied session, and delegates the command to helper run.
cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
last=\$((\${#args[@]} - 1))
flag=\$((last - 1))
if [ "\${#args[@]}" -ge 2 ] \
  && [ "\${args[\$flag]}" = --session ] \
  && [ "\${args[\$last]}" = "$SESSION" ]; then
  unset "args[\$last]" "args[\$flag]"
fi
set -- "\${args[@]}"
for arg in "\$@"; do
  case "\$arg" in --session|--session=*) exit 9 ;; esac
done
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\$@"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }

KIMI_VER=$(PATH="$ORIGINAL_PATH" kimi --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')
NAMED="Kimi Code ($KIMI_VER) on $HERDR_VER"

LAB_SOCKET=$(lab session list --json 2>/dev/null \
  | jq -r --arg s "$SESSION" '.sessions[]? | select(.name == $s) | .socket_path' 2>/dev/null)
[ -n "$LAB_SOCKET" ] || fail "could not read the isolated lab session's socket path"

make_workspace() {  # <cwd> <label> -> prints pane id
  local out
  out=$(lab workspace create --cwd "$1" --label "$2" --no-focus 2>/dev/null) || return 1
  printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null
}

visible() { lab pane read "$1" --source visible 2>/dev/null || true; }
recent() { lab pane read "$1" --source recent --lines 200 2>/dev/null || true; }

# Answer Kimi's folder-trust dialog while the complete dialog is on screen,
# then require the ordinary ready signals. The answer is re-sent on every poll
# the dialog stays up, because the same startup window swallows it.
trust_and_ready() {  # <pane>
  local pane=$1 i=0 v
  while [ "$i" -lt 90 ]; do
    v=$(visible "$pane")
    case "$v" in
      *'Trust this folder?'*'Trust this folder'*"Don't trust"*)
        lab pane send-keys "$pane" enter >/dev/null \
          || fail "$NAMED: could not answer the folder-trust dialog"
        ;;
      *'Trust this folder'* | *"Don't trust"*) ;;
      *)
        case "$v" in
          *'Welcome to Kimi Code!'*)
            [ "$(fm_backend_herdr_composer_state "$SESSION:$pane")" = empty ] && return 0
            ;;
        esac
        ;;
    esac
    i=$((i + 1))
    sleep 1
  done
  return 1
}

# Delivery evidence, mirroring the strict two-signal shape of fm-spawn.sh's
# kimi_delivery_is_confirmed: a cleared composer plus either the echoed
# submission carrying the token or a context meter advanced off zero.
delivered() {  # <pane> <token>
  local pane=$1 token=$2 screen
  [ "$(fm_backend_herdr_composer_state "$SESSION:$pane")" = empty ] || return 1
  screen=$(recent "$pane")
  if { printf '%s\n' "$screen" | grep -Fq '✨' &&
    printf '%s\n' "$screen" | grep -Fq "$token"; } ||
    printf '%s\n' "$screen" |
      grep -qiE 'context:[[:space:]]*(0\.[0-9]*[1-9][0-9]*|[1-9][0-9]*([.][0-9]+)?)[[:space:]]*%'; then
    return 0
  fi
  return 1
}

# --- Phase 1: held pointer + re-sent Enter lands (deterministic) ------------
#
# Type the pointer with NO Enter so the composer provably holds unsubmitted
# text - a strictly stronger "swallowed" state than a dropped Enter, and the
# exact state the delivery wait's re-send must recover.
SCRATCH_CWD="$TMP_ROOT/kimi-cwd"
mkdir -p "$SCRATCH_CWD"
PANE=$(make_workspace "$SCRATCH_CWD" kimi-mech) || fail "could not create the mechanism-proof workspace"
lab pane run "$PANE" "kimi --auto" >/dev/null || fail "could not launch $NAMED in the lab pane"
trust_and_ready "$PANE" || fail "$NAMED never showed a verified ready signal in the lab pane"

TOKEN="KIMIRESEND$$_$RANDOM"
fm_backend_herdr_send_literal "$SESSION:$PANE" "Reply with exactly $TOKEN and nothing else." \
  || fail "$NAMED: literal send of the pointer failed"
sleep 1
state=$(fm_backend_herdr_composer_state "$SESSION:$PANE")
CHECKED=1
[ "$state" = pending ] || [ "$state" = pending-unproven ] \
  || fail "$NAMED: a composer visibly holding the pointer must read pending, got '$state'"

fm_backend_herdr_send_key "$SESSION:$PANE" Enter || fail "$NAMED: Enter re-send failed"
i=0
landed=0
while [ "$i" -lt 30 ]; do
  delivered "$PANE" "$TOKEN" && { landed=1; break; }
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] \
  || fail "$NAMED: the pointer held in the composer never landed after the re-sent Enter"

i=0
replied=0
while [ "$i" -lt 60 ]; do
  occurrences=$(recent "$PANE" | grep -F -c "$TOKEN" || true)
  [ "$occurrences" -ge 2 ] && { replied=1; break; }
  i=$((i + 1))
  sleep 1
done
[ "$replied" = 1 ] \
  || fail "$NAMED: the landed pointer never produced the requested reply"
pass "live kimi delivery: $NAMED reads a held pointer pending and lands it on the re-sent Enter in isolated session $SESSION"

# --- Phase 2: 2.1.1 startup swallow re-check --------------------------------
#
# Race the post-readiness input window the way the incident did: the moment
# the composer first renders, send the pointer and exactly one Enter, then
# watch. Whether or not this run swallows the Enter, a composer still holding
# the pointer must land on one more Enter; the outcome is printed as evidence.
PANE2=$(make_workspace "$SCRATCH_CWD" kimi-swallow) || fail "could not create the swallow re-check workspace"
lab pane run "$PANE2" "kimi --auto" >/dev/null || fail "could not launch $NAMED for the swallow re-check"
i=0
while [ "$i" -lt 90 ]; do
  v=$(visible "$PANE2")
  case "$v" in
    *'Trust this folder?'*'Trust this folder'*"Don't trust"*)
      lab pane send-keys "$PANE2" enter >/dev/null ;;
    *'Welcome to Kimi Code!'*'│ >'* | *'│ >'*'Welcome to Kimi Code!'*) break ;;
  esac
  i=$((i + 1))
  sleep 0.2
done
[ "$i" -lt 90 ] || fail "$NAMED never rendered its composer for the swallow re-check"
TOKEN2="KIMISWALLOW$$_$RANDOM"
fm_backend_herdr_send_literal "$SESSION:$PANE2" "Reply with exactly $TOKEN2 and nothing else." \
  || fail "$NAMED: literal send of the swallow probe failed"
fm_backend_herdr_send_key "$SESSION:$PANE2" Enter || fail "$NAMED: swallow-probe Enter failed"
sleep 2
state=$(fm_backend_herdr_composer_state "$SESSION:$PANE2")
case "$state" in
  pending | pending-unproven)
    printf 'evidence: %s swallowed the first post-readiness Enter; the pointer sat unsubmitted in the composer\n' "$NAMED"
    fm_backend_herdr_send_key "$SESSION:$PANE2" Enter || fail "$NAMED: recovery Enter failed"
    i=0
    landed=0
    while [ "$i" -lt 30 ]; do
      delivered "$PANE2" "$TOKEN2" && { landed=1; break; }
      i=$((i + 1))
      sleep 1
    done
    [ "$landed" = 1 ] \
      || fail "$NAMED: the swallowed pointer never landed after the recovery Enter"
    pass "live kimi swallow re-check: $NAMED swallowed the first Enter and the re-sent Enter still landed it"
    ;;
  *)
    delivered "$PANE2" "$TOKEN2" \
      || fail "$NAMED: composer reads '$state' yet delivery is unconfirmed - neither a held pointer nor a landed one"
    printf 'evidence: %s accepted the first post-readiness Enter in this run; phase 1 carries the held-pointer proof\n' "$NAMED"
    pass "live kimi swallow re-check: $NAMED did not swallow this run's first Enter; mechanism proof stands from phase 1"
    ;;
esac

# --- Phase 3: real spawn, success path --------------------------------------
#
# The real bin/fm-spawn.sh kimi arm end to end against 2.1.1: readiness, a
# deliberately minimal submit budget, the delivery wait with its re-sends,
# and the strict delivery confirmation.
make_scratch_project() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  git -C "$dir" init -q
  printf '# scratch\n' > "$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$dir" "$dir.origin.git"
  git -C "$dir" remote add origin "file://$dir.origin.git"
}

make_brief() {  # <id>
  mkdir -p "$SPAWN_HOME/data/$1"
  cat > "$SPAWN_HOME/data/$1/brief.md" <<'EOF'
# Task
## Captain's intent
Take no action: modify no file and run no command that changes anything.
Reply with the single word READY and stop.

## Firstmate spec
Exercise Kimi dispatch delivery only.
EOF
}

record_worktree() {  # <meta>
  local wt
  wt=$(grep '^worktree=' "$1" 2>/dev/null | cut -d= -f2-)
  [ -n "$wt" ] && WORKTREES+=("$wt")
  return 0
}

spawn_kimi() {  # <id> <project> [extra env assignments...]
  local id=$1 proj=$2
  shift 2
  env -u HERDR_ENV -u HERDR_PANE_ID HERDR_SESSION="$SESSION" \
    HERDR_SOCKET_PATH="$LAB_SOCKET" \
    FM_SPAWN_NO_GUARD=1 FM_HOME="$SPAWN_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    PATH="$FAKEBIN:$ORIGINAL_PATH" "$@" \
    "$ROOT/bin/fm-spawn.sh" "$id" "$proj" --harness kimi --mode no-mistakes --yolo off --backend herdr 2>&1
}

teardown_task() {  # <id>
  local id=$1
  env FM_SPAWN_NO_GUARD=1 FM_HOME="$SPAWN_HOME" FM_ROOT_OVERRIDE="$ROOT" \
    PATH="$FAKEBIN:$ORIGINAL_PATH" \
    "$ROOT/bin/fm-teardown.sh" "$id" >"$TMP_ROOT/teardown-$id.log" 2>&1
}

PROJ_OK="$TMP_ROOT/project-ok"
make_scratch_project "$PROJ_OK"
ID_OK="kimi-live-ok-$$"
make_brief "$ID_OK"
out=$(spawn_kimi "$ID_OK" "$PROJ_OK" FM_KIMI_SUBMIT_RETRIES=1) && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "$NAMED: real kimi spawn failed with a minimal submit budget: $out"
case "$out" in
  *"spawned $ID_OK harness=kimi"*) ;;
  *) fail "$NAMED: real kimi spawn did not report success: $out" ;;
esac
record_worktree "$SPAWN_HOME/state/$ID_OK.meta"
teardown_task "$ID_OK" || fail "$NAMED: teardown of the successful live spawn failed"
pass "live kimi spawn: $NAMED launches, delivers, and confirms its brief pointer through the real spawn"

# --- Phase 4: real spawn, failed delivery rolls back and is cleaned up here -
#
# A zero delivery poll budget forces the delivery gate to fail after the pane
# and worktree exist - the 2026-09-25 incident's shape. The provisional record
# is rolled back so the backlog row stays queued and re-dispatchable. The
# pane, local copy, slot claim, and hook token then have no owner (giving them
# one is separately filed work), so this guard locates each through the
# spawn's own diagnostics and cleans them up itself, failing loudly if any is
# missing or any cleanup leaves a trace.
PROJ_FAIL="$TMP_ROOT/project-fail"
make_scratch_project "$PROJ_FAIL"
ID_FAIL="kimi-live-fail-$$"
make_brief "$ID_FAIL"
out=$(spawn_kimi "$ID_FAIL" "$PROJ_FAIL" FM_KIMI_DELIVERY_POLLS=0) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "$NAMED: a zero-budget delivery gate should fail the spawn"
case "$out" in
  *'kimi brief pointer delivery was not confirmed'*) ;;
  *) fail "$NAMED: the forced delivery failure lacked its diagnostic: $out" ;;
esac
[ ! -e "$SPAWN_HOME/state/$ID_FAIL.meta" ] && [ ! -L "$SPAWN_HOME/state/$ID_FAIL.meta" ] \
  || fail "$NAMED: the failed spawn kept its provisional task record instead of rolling it back"
fail_pane=$(printf '%s\n' "$out" | sed -nE "s/.*inspect window $SESSION:([^[:space:];]+).*/\\1/p" | head -1)
[ -n "$fail_pane" ] || fail "$NAMED: the forced delivery failure did not name its pane: $out"
fail_wt=$(printf '%s\n' "$out" | sed -nE "s/.*leaving task $ID_FAIL's slot claim on (.*) in place;.*/\\1/p" | head -1)
[ -n "$fail_wt" ] && [ -d "$fail_wt" ] \
  || fail "$NAMED: the forced delivery failure did not name its stranded local copy: $out"
fail_claim="$(dirname "$fail_wt")/.fm-slot-owner"
grep -qx "task=$ID_FAIL" "$fail_claim" 2>/dev/null \
  || fail "$NAMED: the stranded local copy's slot claim does not name the failed spawn"
[ -f "$fail_wt/.fm-kimi-turnend" ] \
  || fail "$NAMED: the stranded local copy carries no hook-token pointer"
fail_token=$(head -1 "$SPAWN_HOME/state/$ID_FAIL.kimi-turnend-token" 2>/dev/null || true)
case "$fail_token" in
  ''|*[!A-Za-z0-9._-]*) fail "$NAMED: the failed spawn left no readable hook token in its state" ;;
esac
fail_auth="$HOME/.kimi-code/fm-turn-end.d/$fail_token"
[ -f "$fail_auth" ] || fail "$NAMED: the failed spawn's hook token is not registered at $fail_auth"
lab pane get "$fail_pane" >/dev/null 2>&1 \
  || fail "$NAMED: the failed spawn's pane $fail_pane is not running"

fm_backend_herdr_explicit_close_pane_confirmed "$SESSION" "$fail_pane" \
  || fail "$NAMED: could not close the failed spawn's stranded pane $fail_pane"
rm -f -- "$fail_auth" "$fail_wt/.fm-kimi-turnend" \
  "$SPAWN_HOME/state/$ID_FAIL.kimi-turnend-token" "$fail_claim"
env PATH="$ORIGINAL_PATH" treehouse return --force "$fail_wt" >"$TMP_ROOT/return-$ID_FAIL.log" 2>&1 \
  || fail "$NAMED: could not return the failed spawn's stranded local copy: $(cat "$TMP_ROOT/return-$ID_FAIL.log")"

if lab pane get "$fail_pane" >/dev/null 2>&1; then
  fail "$NAMED: the failed spawn's pane survived its close"
fi
[ ! -e "$fail_auth" ] || fail "$NAMED: the failed spawn's hook token survived its removal"
[ ! -e "$fail_claim" ] || fail "$NAMED: the failed spawn's slot-owner claim survived its removal"
# The slot is back in the pool: treehouse keeps the scrubbed path as pool
# inventory, its state entry carries no owner_pid, and no task state remains.
if [ -d "$fail_wt" ]; then
  pool_state=$(dirname "$(dirname "$fail_wt")")/treehouse-state.json
  [ ! -e "$fail_wt/.fm-kimi-turnend" ] \
    || fail "$NAMED: the failed spawn's token pointer survived the return of its local copy"
  if [ -f "$pool_state" ]; then
    leased=$(jq -r --arg p "$fail_wt" '.worktrees[]? | select(.path == $p) | .owner_pid // empty' "$pool_state" 2>/dev/null || true)
    [ -z "$leased" ] \
      || fail "$NAMED: the failed spawn's slot is still leased to pid $leased in the pool"
  fi
fi
pass "live kimi spawn failure: $NAMED rolls the failed delivery's record back and its stranded pane, local copy, slot claim, and hook token clean up"

[ "$CHECKED" -gt 0 ] || fail "FM_KIMI_DELIVERY_RESEND_LIVE=1 checked no harness"
