#!/usr/bin/env bash
# Behavior tests for the helm layer: bin/fm-helm.sh, bin/fm-helm-lib.sh, the
# epoch fencing in control-root/verbs/fmr-verb.sh, and the gate the five
# state-changing commands now carry.
#
# Two "machines" are simulated on one filesystem: two firstmate homes, each with
# its own control root and its own view of the other as a relay host, talking
# through a stub `bifrost` that executes the verb locally with an EMPTY
# environment - the same condition the real relay imposes, and the one that
# would otherwise let a test pass because it inherited FM_HOME from the caller.
#
# What is deliberately NOT tested, because it is deliberately not built: any
# form of automatic takeover. There is no liveness probe, no grace period, and
# no heartbeat to test, per the captain's 2026-08-01 decision that changing
# control machines is a human action.
#
# What IS tested is what explicit handover needs to be right on its own:
#   - a stale control plane is refused BY THE MACHINE IT COMMANDS (fencing),
#     which is the only refusal that does not rely on the stale side's honesty;
#   - a demoted machine cannot merge, anywhere, by any route;
#   - two simultaneous claims produce exactly one winner and exactly one epoch;
#   - a handover moves supervision without restarting or losing anything;
#   - and none of it exists at all on a machine that never joined a fleet.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-helm)
FLEET=testfleet

# --- the stub relay ----------------------------------------------------------
#
# `bifrost remote ... exec --shell-text "<verb> <args>"` runs the verb here, and
# `bifrost remote ... file ...` copies within this filesystem. Both machines are
# real directories, so every cross-machine call in these tests goes through the
# real client, the real argument allowlist, and the real verb.
make_stub_bifrost() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/bifrost" <<'SH'
#!/usr/bin/env bash
# Stub Bifrost. Only the two shapes bin/fm-relay-lib.sh uses are implemented.
set -u
mode=; text=; prev=; sub=; fargs=()
for a in "$@"; do
  case "$prev" in
    --shell-text) text=$a ;;
  esac
  case "$a" in
    exec) [ -z "$mode" ] && mode=exec ;;
    file) [ -z "$mode" ] && mode=file ;;
  esac
  if [ "$mode" = file ] && [ "$a" != file ]; then
    if [ -z "$sub" ]; then
      case "$a" in write|hash|download|delete) sub=$a ;; esac
    else
      fargs+=("$a")
    fi
  fi
  prev=$a
done
hash_of() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else sha256sum "$1" | awk '{print $1}'; fi
}
case "$mode" in
  exec)
    [ -n "$text" ] || { echo "stub: no shell text" >&2; exit 2; }
    # An EMPTY environment, exactly like the policy layer: no HOME, no FM_HOME,
    # nothing the caller happened to export. PATH is the one concession, because
    # the real target has a login PATH the verb then replaces from its config.
    env -i PATH="$PATH" bash -c "$text"
    exit $?
    ;;
  file)
    case "$sub" in
      write)
        dest=${fargs[0]}; src=
        i=0
        while [ "$i" -lt "${#fargs[@]}" ]; do
          [ "${fargs[$i]}" = "--from-local" ] && src=${fargs[$((i+1))]}
          i=$((i+1))
        done
        mkdir -p "$(dirname "$dest")"
        cp "$src" "$dest"
        ;;
      hash) printf 'sha256: %s\n' "$(hash_of "${fargs[0]}")" ;;
      download) cp "${fargs[0]}" "${fargs[1]}" ;;
      delete) rm -f "${fargs[0]}" ;;
      *) echo "stub: unsupported file op '$sub'" >&2; exit 2 ;;
    esac
    exit 0
    ;;
esac
echo "stub: unsupported bifrost call: $*" >&2
exit 2
SH
  chmod +x "$dir/bifrost"
}

# --- fleet fixture -----------------------------------------------------------
#
# Two machines, `mac` and `box`, with `box` as the anchor - the same asymmetry
# the real fleet has, where the always-on machine holds the authoritative copy.
build_fleet() {  # <root>
  local root=$1 m
  for m in mac box; do
    mkdir -p "$root/$m/state" "$root/$m/data" "$root/$m/config" "$root/$m/projects" \
      "$root/$m/cr/verbs" "$root/$m/cr/tasks" "$root/$m/fr/tasks"
    cp "$ROOT/control-root/verbs/fmr-verb.sh" "$root/$m/cr/verbs/fmr-verb.sh"
    chmod 755 "$root/$m/cr/verbs/fmr-verb.sh"
    cat > "$root/$m/cr/config" <<EOF
FM_ROOT=$ROOT
FM_HOME=$root/$m
HOME_DIR=$root/$m
PATH=$PATH
PROJECTS=$root/$m/projects
FLEET_ROOT=$root/$m/fr
LANG=en_US.UTF-8
EOF
    cat > "$root/$m/config/fleet.json" <<EOF
{ "fleet": "$FLEET", "machine": "$m", "control_root": "$root/$m/cr", "anchor": "box" }
EOF
  done
  write_registry "$root/mac" box "$root/box" "$FLEET"
  write_registry "$root/box" mac "$root/mac" "$FLEET"
}

write_registry() {  # <home> <peer-name> <peer-root> <fleet-or-empty>
  local home=$1 peer=$2 proot=$3 fleet=$4 fleet_line=''
  [ -z "$fleet" ] || fleet_line=",
    \"fleet\": \"$fleet\""
  cat > "$home/config/relay-hosts.json" <<EOF
{
  "$peer": {
    "client_id": "cid-$peer",
    "control_root": "$proot/cr",
    "fleet_root": "$proot/fr",
    "home": "$proot",
    "root": "$ROOT",
    "path": "$PATH"$fleet_line
  }
}
EOF
}

helm() {  # <machine> <args...>
  local m=$1
  shift
  FM_HOME="$TMP_ROOT/$m" FM_RELAY_BIFROST="$STUB/bifrost" \
    "$ROOT/bin/fm-helm.sh" "$@" 2>&1
}

lease_line() {  # <machine>
  local f="$TMP_ROOT/$1/cr/helm/lease"
  [ -f "$f" ] || { printf 'ABSENT'; return 0; }
  printf '%s %s' "$(grep '^epoch=' "$f" | cut -d= -f2-)" \
    "$(grep '^holder=' "$f" | cut -d= -f2-)"
}

verb() {  # <machine> <args...>
  local m=$1
  shift
  "$TMP_ROOT/$m/cr/verbs/fmr-verb.sh" "$@" 2>&1
}

STUB="$TMP_ROOT/stub"
make_stub_bifrost "$STUB"
# Echoes back the shell text it was asked to run, so a test can inspect exactly
# what would go over the wire instead of inferring it.
cat > "$TMP_ROOT/echo-bifrost" <<'SH'
#!/usr/bin/env bash
prev=
for a in "$@"; do [ "$prev" = "--shell-text" ] && { printf '%s\n' "$a"; exit 0; }; prev=$a; done
exit 1
SH
chmod +x "$TMP_ROOT/echo-bifrost"
build_fleet "$TMP_ROOT"

# --- the single-machine guarantee, asserted directly -------------------------
#
# tests/fm-helm-single-machine.test.sh proves this against a transcript captured
# before the gate existed. This asserts the mechanism underneath it: on a home
# with no fleet record the gate reads nothing, says nothing, and passes.
test_no_fleet_is_inert() {
  local home="$TMP_ROOT/solo" out rc=0
  mkdir -p "$home/state" "$home/config"
  # shellcheck source=bin/fm-helm-lib.sh
  . "$ROOT/bin/fm-helm-lib.sh"
  out=$(fm_helm_assert "$home" "doing something" 2>&1) || rc=$?
  expect_code 0 "$rc" "the helm gate must pass on a home that declared no fleet"
  [ -z "$out" ] || fail "the helm gate must print nothing on a fleetless home, got: $out"
  out=$(fm_helm_epoch_for_home "$home")
  [ -z "$out" ] || fail "a fleetless home must contribute no fencing token, got: $out"
  pass "no fleet record: the gate passes silently and adds no fencing token"
}

# A relay host that never joined a fleet must keep taking un-fenced commands, or
# every Phase 1/2 dispatch breaks the day this code ships.
test_host_without_a_lease_is_not_fenced() {
  local out
  printf 'window=w1\nworktree=/tmp/x\nkind=scout\n' > "$TMP_ROOT/box/state/legacy.meta"
  rm -rf "$TMP_ROOT/box/cr/helm"
  out=$(verb box ack legacy 12)
  assert_contains "$out" "OK ack=12" "a host with no lease must accept a command carrying no epoch"
  pass "no lease on the host: commands are not fenced (Phase 1/2 stays working)"
}

test_claim_and_handover() {
  local out
  out=$(helm box claim)
  assert_contains "$out" "helm claimed: box" "box must be able to take a free helm"
  [ "$(lease_line box)" = "1 box" ] || fail "anchor lease after claim: $(lease_line box)"
  [ "$(lease_line mac)" = "1 box" ] || fail "mac copy after claim: $(lease_line mac)"

  out=$(helm mac status --brief) || true
  assert_contains "$out" "box is the control plane" "mac must report itself read-only"

  out=$(helm box handover mac)
  assert_contains "$out" "helm moved: box -> mac" "handover must report the move"
  [ "$(lease_line box)" = "2 mac" ] || fail "anchor lease after handover: $(lease_line box)"
  [ "$(lease_line mac)" = "2 mac" ] || fail "mac copy after handover: $(lease_line mac)"

  out=$(helm box handover mac 2>&1 || true)
  assert_contains "$out" "does not hold the helm" \
    "a machine that gave the helm away must not be able to hand it over again"
  pass "claim then handover: both copies move together and the loser knows"
}

# The captain's own path: the helm is given away by whoever holds it. Pulling it
# from the far side is the forced escape hatch, and it has to say what it cannot
# check rather than pretending it verified anything.
test_claim_refuses_to_take_a_held_helm() {
  local out rc=0
  out=$(helm box claim 2>&1) || rc=$?
  expect_code 1 "$rc" "claim must refuse while another machine holds the helm"
  assert_contains "$out" "mac holds the helm" "the refusal must name the holder"
  assert_contains "$out" "handover box" "the refusal must name the command that does work"
  [ "$(lease_line box)" = "2 mac" ] || fail "a refused claim must change nothing: $(lease_line box)"

  out=$(helm box claim --force)
  assert_contains "$out" "FORCED CLAIM" "a forced claim must announce itself"
  assert_contains "$out" "cannot verify" "a forced claim must state what it did not check"
  [ "$(lease_line box)" = "3 box" ] || fail "forced claim lease: $(lease_line box)"
  pass "claim: refuses a held helm, and says what --force cannot verify"
}

# Two machines racing for a helm nobody holds. The anchor's compare-and-swap is
# the arbiter, so the outcome is decided rather than merely unlikely to collide.
test_simultaneous_claims_produce_one_winner_and_one_epoch() {
  local before after wins=0
  helm box demote >/dev/null
  before=$(lease_line box); before=${before%% *}
  helm mac claim > "$TMP_ROOT/claim-mac.out" 2>&1 &
  local p1=$!
  helm box claim > "$TMP_ROOT/claim-box.out" 2>&1 &
  local p2=$!
  wait "$p1" || true
  wait "$p2" || true
  grep -q 'helm claimed' "$TMP_ROOT/claim-mac.out" && wins=$((wins + 1))
  grep -q 'helm claimed' "$TMP_ROOT/claim-box.out" && wins=$((wins + 1))
  [ "$wins" -eq 1 ] || {
    printf -- '--- mac ---\n'; cat "$TMP_ROOT/claim-mac.out"
    printf -- '--- box ---\n'; cat "$TMP_ROOT/claim-box.out"
    fail "exactly one simultaneous claim must win, got $wins"
  }
  after=$(lease_line box); after=${after%% *}
  [ "$after" -eq "$((before + 1))" ] \
    || fail "two simultaneous claims must advance the epoch by exactly one: $before -> $after"
  # The loser has to be readable, not just unsuccessful.
  if grep -q 'helm claimed' "$TMP_ROOT/claim-mac.out"; then
    grep -qE 'REFUSED|holds the helm|did not move' "$TMP_ROOT/claim-box.out" \
      || { cat "$TMP_ROOT/claim-box.out"; fail "the losing claim must say what happened"; }
  else
    grep -qE 'REFUSED|holds the helm|did not move' "$TMP_ROOT/claim-mac.out" \
      || { cat "$TMP_ROOT/claim-mac.out"; fail "the losing claim must say what happened"; }
  fi
  pass "simultaneous claims: exactly one winner, epoch advances by exactly one"
}

# Two sessions on the SAME holder handing the helm away at once - the other
# shape the compare-and-swap has to survive.
test_simultaneous_handovers_from_one_holder() {
  local holder other before after wins=0
  holder=$(lease_line box); holder=${holder##* }
  other=mac; [ "$holder" = mac ] && other=box
  before=$(lease_line box); before=${before%% *}
  helm "$holder" handover "$other" > "$TMP_ROOT/ho-1.out" 2>&1 &
  local p1=$!
  helm "$holder" handover "$other" > "$TMP_ROOT/ho-2.out" 2>&1 &
  local p2=$!
  wait "$p1" || true
  wait "$p2" || true
  grep -q 'helm moved' "$TMP_ROOT/ho-1.out" && wins=$((wins + 1))
  grep -q 'helm moved' "$TMP_ROOT/ho-2.out" && wins=$((wins + 1))
  [ "$wins" -eq 1 ] || {
    printf -- '--- 1 ---\n'; cat "$TMP_ROOT/ho-1.out"
    printf -- '--- 2 ---\n'; cat "$TMP_ROOT/ho-2.out"
    fail "exactly one of two simultaneous handovers must land, got $wins"
  }
  after=$(lease_line box); after=${after%% *}
  [ "$after" -eq "$((before + 1))" ] \
    || fail "two simultaneous handovers must advance the epoch by exactly one: $before -> $after"
  pass "simultaneous handovers from one holder: one lands, epoch advances by exactly one"
}

# --- fencing -----------------------------------------------------------------

# Freeze a machine at an old epoch WITHOUT telling it, which is what a control
# plane that handed the helm over and kept running looks like from the inside.
freeze_at() {  # <machine> <epoch> <holder>
  local m=$1 epoch=$2 holder=$3
  mkdir -p "$TMP_ROOT/$m/cr/helm"
  cat > "$TMP_ROOT/$m/cr/helm/lease" <<EOF
helm-v1
fleet=$FLEET
epoch=$epoch
holder=$holder
updated_at=1970-01-01T00:00:00Z
by=test
forced=0
EOF
}

test_stale_control_plane_is_refused_by_the_peer() {
  local out before_meta after_meta
  # box is the anchor and the holder; mac is frozen believing it still holds an
  # older epoch. Its own gate will therefore let it act - which is the point:
  # the refusal has to come from the machine being commanded.
  helm box claim --force >/dev/null
  local epoch; epoch=$(lease_line box); epoch=${epoch%% *}
  freeze_at mac "$((epoch - 1))" mac

  printf 'window=w9\nworktree=%s/box/wt\nkind=ship\nproject=%s/box/projects/p\n' \
    "$TMP_ROOT" "$TMP_ROOT" > "$TMP_ROOT/box/state/fenced.meta"
  mkdir -p "$TMP_ROOT/box/cr/tasks/fenced"
  printf 'claimed_at=x\n' > "$TMP_ROOT/box/cr/tasks/fenced/claim"
  before_meta=$(cat "$TMP_ROOT/box/state/fenced.meta")

  # mac's control-side record of the same task, pointing at box.
  cp "$TMP_ROOT/box/state/fenced.meta" "$TMP_ROOT/mac/state/fenced.meta"
  printf 'host=box\n' >> "$TMP_ROOT/mac/state/fenced.meta"

  out=$(FM_HOME="$TMP_ROOT/mac" FM_RELAY_BIFROST="$STUB/bifrost" \
    "$ROOT/bin/fm-send.sh" fenced "do something" 2>&1 || true)
  assert_contains "$out" "EPOCH_STALE" "a steer from a stale control plane must be refused by the peer"

  out=$(FM_HOME="$TMP_ROOT/mac" FM_RELAY_BIFROST="$STUB/bifrost" \
    "$ROOT/bin/fm-teardown.sh" fenced 2>&1 || true)
  assert_contains "$out" "EPOCH_STALE" "a cleanup from a stale control plane must be refused by the peer"

  after_meta=$(cat "$TMP_ROOT/box/state/fenced.meta")
  [ "$before_meta" = "$after_meta" ] || fail "a fenced call must leave the peer's record untouched"
  [ -d "$TMP_ROOT/box/cr/tasks/fenced" ] || fail "a fenced cleanup must not remove the peer's task record"
  [ -f "$TMP_ROOT/box/state/fenced.meta" ] || fail "a fenced cleanup must not remove the peer's metadata"
  pass "fencing: a stale control plane is refused BY THE PEER, which changes nothing"
}

test_missing_epoch_is_refused_too() {
  local out epoch
  epoch=$(lease_line box); epoch=${epoch%% *}
  # The RIGHT epoch has to be accepted, and this assertion is not optional: a
  # fence that refused everything would pass every refusal test above while
  # making the fleet unusable.
  out=$(verb box "ack@$epoch" fenced 5)
  assert_contains "$out" "OK ack=5" "the current epoch must be ACCEPTED, not just non-stale ones refused"
  # Treating "no token" as "not fenced" would let a stale caller opt out of the
  # check by simply not sending one.
  out=$(verb box ack fenced 5)
  assert_contains "$out" "EPOCH_STALE" "a command with no epoch must be refused once a lease exists"
  out=$(verb box ack@999999 fenced 5)
  assert_contains "$out" "EPOCH_STALE" "a command with a wrong epoch must be refused"
  out=$(verb box ack@notanumber fenced 5)
  assert_contains "$out" "EPOCH_STALE" "an unreadable epoch must be refused, not treated as absent"
  pass "fencing: the current epoch is accepted; absent, wrong, and unreadable are all refused"
}

# The constraint that decides HOW the epoch travels, pinned so a later change
# cannot quietly break every remote dispatch.
#
# The deployed shell policy is `^<path>/fmr-verb\.sh( [A-Za-z0-9._@=+-]{1,96}){0,8}$`
# - this entry point plus AT MOST EIGHT arguments. `spawn` already sends eight.
# A ninth token is refused by the policy layer before the verb runs, and
# widening the allowlist invalidates the grant and forces a re-pair, so the
# fencing epoch has to fit inside the existing budget rather than add to it.
test_fenced_calls_stay_inside_the_policy_argument_budget() {
  local home="$TMP_ROOT/budget" text n
  mkdir -p "$home/config" "$home/cr/helm"
  cat > "$home/config/fleet.json" <<EOF
{ "fleet": "$FLEET", "machine": "b", "control_root": "$home/cr", "anchor": "b" }
EOF
  printf 'helm-v1
fleet=%s
epoch=4242
holder=b
' "$FLEET" > "$home/cr/helm/lease"
  # Capture exactly what would go over the wire for the widest verb there is.
  # The subshell is the point: it sources the real library and sets the real
  # globals without leaking either into the rest of this file.
  # shellcheck disable=SC2030,SC2031  # subshell-local by design
  text=$(
    # shellcheck source=bin/fm-relay-lib.sh
    . "$ROOT/bin/fm-relay-lib.sh"
    FM_HOME="$home"
    FM_RELAY_HOST=box
    FM_RELAY_VERB=/verbs/fmr-verb.sh
    FM_RELAY_CLIENT_ID=cid
    FM_RELAY_BIFROST="$TMP_ROOT/echo-bifrost"
    fm_relay_exec spawn t1 ship proj brief.md claude opus high >/dev/null 2>&1
    printf '%s' "$FM_RELAY_OUT"
  )
  n=$(printf '%s' "$text" | awk '{print NF - 1}')
  [ "$n" -le 8 ]     || fail "a fenced spawn sends $n arguments; the deployed policy allows 8, so it would be refused before the verb ran: $text"
  case "$text" in
    *' spawn@4242 '*) ;;
    *) fail "the fencing epoch must ride on the verb token: $text" ;;
  esac
  pass "fencing: a fenced spawn still fits the deployed policy's 8-argument budget"
}

test_read_only_verbs_stay_open_to_a_stale_machine() {
  local out
  # A demoted machine must still be able to SEE what is running - that is how it
  # finds out it was demoted, and how a captain diagnoses the fleet from it.
  out=$(verb box helm-read)
  assert_contains "$out" "OK epoch=" "helm-read must never be fenced"
  out=$(verb box task-list)
  assert_contains "$out" "OK" "task-list must never be fenced"
  pass "fencing: reading is always allowed, changing is not"
}

# --- the demoted machine cannot land work ------------------------------------

test_demoted_machine_refuses_both_merges() {
  local out rc=0 proj="$TMP_ROOT/mac/projects/alpha"
  # A real repo with a real fast-forward available, so a refusal cannot be
  # mistaken for "there was nothing to merge anyway".
  git init -q "$proj"
  git -C "$proj" -c user.name=t -c user.email=t@e.invalid commit -q --allow-empty -m base
  git -C "$proj" branch -q -M main
  git -C "$proj" -c user.name=t -c user.email=t@e.invalid commit -q --allow-empty -m work
  git -C "$proj" branch -q fm/landme
  git -C "$proj" reset -q --hard HEAD~1
  local head_before; head_before=$(git -C "$proj" rev-parse main)
  cat > "$TMP_ROOT/mac/state/landme.meta" <<EOF
window=w
worktree=$TMP_ROOT/mac/wt
project=$proj
kind=ship
mode=local-only
yolo=on
EOF
  # mac is frozen as a NON-holder here: box holds the helm.
  freeze_at mac "$(lease_line box | cut -d' ' -f1)" box

  out=$(FM_HOME="$TMP_ROOT/mac" "$ROOT/bin/fm-merge-local.sh" landme 2>&1) || rc=$?
  expect_code 1 "$rc" "a demoted machine must refuse a local merge"
  assert_contains "$out" "REFUSED" "the local-merge refusal must be explicit"
  assert_contains "$out" "box holds the helm" "the refusal must name the control plane"
  [ "$(git -C "$proj" rev-parse main)" = "$head_before" ] \
    || fail "a refused merge must not move the branch"

  rc=0
  out=$(FM_HOME="$TMP_ROOT/mac" "$ROOT/bin/fm-pr-merge.sh" landme \
    https://github.com/o/r/pull/1 2>&1) || rc=$?
  expect_code 1 "$rc" "a demoted machine must refuse a PR merge"
  assert_contains "$out" "REFUSED" "the PR-merge refusal must be explicit"
  pass "demoted machine: both merge paths refuse and nothing lands"
}

test_demoted_machine_refuses_to_start_or_steer_work() {
  local out rc=0
  out=$(FM_HOME="$TMP_ROOT/mac" "$ROOT/bin/fm-spawn.sh" newtask \
    "$TMP_ROOT/mac/projects/alpha" 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "a demoted machine must refuse to start a task"
  assert_contains "$out" "REFUSED" "the spawn refusal must be explicit"
  [ -f "$TMP_ROOT/mac/state/newtask.meta" ] && fail "a refused spawn must record nothing"
  pass "demoted machine: starting work refuses before anything is recorded"
}

# A machine that finds the helm gone from under it has lost something a handover
# would have told it about, so it says so instead of silently going read-only.
test_surprise_demotion_is_reported_and_sticky() {
  local out
  helm box claim --force >/dev/null
  helm box handover mac >/dev/null
  # box quietly takes it back without mac taking part, which is what a forced
  # claim against an unreachable machine looks like from mac's side.
  local e; e=$(lease_line box); e=${e%% *}
  verb box helm-set "fleet=$FLEET" "expect=$e" "next=$((e + 1))" holder=box by=box force=1 >/dev/null
  out=$(helm mac status --refresh --brief || true)
  assert_contains "$out" "lost the helm" "mac must be told it lost the helm"
  [ -f "$TMP_ROOT/mac/state/.helm-lost" ] || fail "a surprise demotion must leave a durable record"
  out=$(FM_HOME="$TMP_ROOT/mac" "$ROOT/bin/fm-send.sh" fenced hello 2>&1 || true)
  assert_contains "$out" "REFUSED" "the lost-helm state must refuse every change"
  rm -f "$TMP_ROOT/mac/state/.helm-lost"
  pass "surprise demotion: reported once, durable, and refuses everything until cleared"
}

# --- discovery ---------------------------------------------------------------

test_task_list_reports_this_machines_own_work() {
  local out
  rm -f "$TMP_ROOT/mac"/state/*.meta
  printf 'window=w1\nworktree=/tmp/a\nkind=ship\n' > "$TMP_ROOT/mac/state/own.meta"
  printf 'window=w2\nworktree=/tmp/b\nkind=secondmate\nhome=/tmp/b\n' > "$TMP_ROOT/mac/state/sub.meta"
  printf 'window=w3\nworktree=/tmp/c\nkind=ship\nhost=box\n' > "$TMP_ROOT/mac/state/mirror.meta"
  out=$(verb mac task-list)
  assert_contains "$out" "own kind=ship" "a locally started task must be discoverable"
  assert_not_contains "$out" "sub " "a persistent secondmate is not a task and must not be listed"
  assert_not_contains "$out" "mirror " "a mirror of another machine's task must not be listed back"
  pass "task-list: this machine's own work only - no secondmates, no mirrors"
}

test_adopt_picks_up_peer_work_without_touching_it() {
  local out
  helm box claim --force >/dev/null
  rm -f "$TMP_ROOT/box"/state/*.meta "$TMP_ROOT/mac"/state/*.meta
  rm -rf "$TMP_ROOT/mac/cr/tasks/adoptme"
  cat > "$TMP_ROOT/mac/state/adoptme.meta" <<EOF
window=firstmate:fm-adoptme
worktree=$TMP_ROOT/mac/wt-adoptme
project=$TMP_ROOT/mac/projects/alpha
harness=claude
kind=scout
mode=local-only
yolo=off
EOF
  local before; before=$(cat "$TMP_ROOT/mac/state/adoptme.meta")
  mkdir -p "$TMP_ROOT/mac/cr/tasks/adoptme"
  printf '41\n' > "$TMP_ROOT/mac/cr/tasks/adoptme/ack"

  # A SECOND task, because adopting one and losing the rest is the shape this
  # loop fails in: each iteration runs another cross-machine call.
  cat > "$TMP_ROOT/mac/state/adoptme2.meta" <<EOF
window=firstmate:fm-adoptme2
worktree=$TMP_ROOT/mac/wt-adoptme2
project=$TMP_ROOT/mac/projects/alpha
kind=ship
EOF

  out=$(helm box adopt)
  assert_contains "$out" "adopted adoptme from mac" "adopt must pick up the peer's task"
  assert_contains "$out" "adopted adoptme2 from mac" "adopt must pick up EVERY task, not just the first"
  [ -f "$TMP_ROOT/box/state/adoptme2.meta" ] || fail "the second adopted task must be recorded too"
  assert_contains "$out" "offset 41" "adopt must resume from what the peer recorded as presented"
  [ -f "$TMP_ROOT/box/state/adoptme.meta" ] || fail "adopt must record the task on the new control plane"
  assert_grep 'host=mac' "$TMP_ROOT/box/state/adoptme.meta" "the adopted record must point back at the machine running it"
  assert_grep 'worktree=' "$TMP_ROOT/box/state/adoptme.meta" "the adopted record must carry the real worktree"
  [ "$(cat "$TMP_ROOT/box/state/adoptme.relay-ack")" = 41 ] \
    || fail "adopt must seed the event cursor from the peer"
  [ -f "$TMP_ROOT/box/state/adoptme.check.sh" ] || fail "adopt must arm notifications for the adopted task"
  [ -f "$TMP_ROOT/box/state/adoptme.check-trust" ] || fail "the armed check must be registered"
  [ "$(cat "$TMP_ROOT/mac/state/adoptme.meta")" = "$before" ] \
    || fail "adopt must not modify the task on the machine running it"
  pass "adopt: supervision moves, the task does not"
}

test_adopt_refuses_an_id_collision() {
  local out rc=0
  printf 'window=local\nworktree=/tmp/local\nkind=ship\n' > "$TMP_ROOT/box/state/adoptme.meta"
  out=$(helm box adopt) || rc=$?
  expect_code 1 "$rc" "adopt must report a collision as a problem"
  assert_contains "$out" "DIFFERENT local task already uses that id" \
    "adopt must name an id collision instead of overwriting"
  assert_grep 'window=local' "$TMP_ROOT/box/state/adoptme.meta" \
    "adopt must leave the colliding local record exactly as it was"
  pass "adopt: an id collision refuses instead of overwriting a local task"
}

# The whole of acceptance criterion 1, end to end: a live task on each machine,
# the helm moves, and afterwards the new control plane supervises both without
# anything being restarted, any event being lost, or an unanswered question
# becoming unanswerable.
test_handover_end_to_end() {
  local out before_mac before_box
  # Start from a clean fleet with box holding the helm and mac about to take it.
  rm -f "$TMP_ROOT/mac"/state/*.meta "$TMP_ROOT/box"/state/*.meta \
    "$TMP_ROOT/mac"/state/*.check.sh "$TMP_ROOT/box"/state/*.check.sh \
    "$TMP_ROOT/mac"/state/*.check-trust "$TMP_ROOT/box"/state/*.check-trust \
    "$TMP_ROOT/mac/state/.helm-lost" "$TMP_ROOT/box/state/.helm-lost"
  rm -rf "$TMP_ROOT/mac/cr/tasks" "$TMP_ROOT/box/cr/tasks"
  mkdir -p "$TMP_ROOT/mac/cr/tasks" "$TMP_ROOT/box/cr/tasks"
  helm mac claim --force >/dev/null

  # One task on each machine, each with an unanswered question in its log.
  local m
  for m in mac box; do
    cat > "$TMP_ROOT/$m/state/live-$m.meta" <<EOF
window=firstmate:fm-live-$m
worktree=$TMP_ROOT/$m/wt-live-$m
project=$TMP_ROOT/$m/projects/alpha
harness=claude
kind=ship
mode=direct-PR
yolo=off
EOF
    printf 'working: started\nneeds-decision: which base branch?\n' \
      > "$TMP_ROOT/$m/state/live-$m.status"
  done
  # mac already supervises box's task, the way it would after dispatching it.
  cp "$TMP_ROOT/box/state/live-box.meta" "$TMP_ROOT/mac/state/live-box.meta"
  printf 'host=box\n' >> "$TMP_ROOT/mac/state/live-box.meta"
  before_mac=$(cat "$TMP_ROOT/mac/state/live-mac.meta")
  before_box=$(cat "$TMP_ROOT/box/state/live-box.meta")

  out=$(helm mac handover box)
  assert_contains "$out" "helm moved: mac -> box" "the handover must report the move"

  out=$(helm box adopt)
  assert_contains "$out" "adopted live-mac from mac" "the new control plane must pick up the other machine's task"

  # Both tasks are now supervised from box: its own directly, mac's as a mirror.
  [ -f "$TMP_ROOT/box/state/live-box.meta" ] || fail "box must still hold its own task record"
  [ -f "$TMP_ROOT/box/state/live-mac.meta" ] || fail "box must now hold a record for mac's task"
  assert_grep 'host=mac' "$TMP_ROOT/box/state/live-mac.meta" "the adopted record must point at mac"

  # Nothing was restarted and nothing on the machines running the work changed.
  [ "$(cat "$TMP_ROOT/mac/state/live-mac.meta")" = "$before_mac" ] \
    || fail "a handover must not touch the task running on the machine that gave the helm away"
  [ "$(cat "$TMP_ROOT/box/state/live-box.meta")" = "$before_box" ] \
    || fail "a handover must not touch the task running on the machine that took the helm"

  # No event is lost: the unanswered question is still there to be read, because
  # the cursor resumes from what was actually presented, not from the end.
  out=$(FM_HOME="$TMP_ROOT/box" FM_RELAY_BIFROST="$STUB/bifrost" \
    "$ROOT/bin/fm-relay-host.sh" events live-mac 2>&1)
  assert_contains "$out" "needs-decision: which base branch?" \
    "the new control plane must still see the unanswered question"

  # And it can be answered: the new holder's steer reaches the other machine.
  out=$(FM_HOME="$TMP_ROOT/box" FM_RELAY_BIFROST="$STUB/bifrost" \
    "$ROOT/bin/fm-relay-host.sh" send live-mac "use main" 2>&1 || true)
  assert_not_contains "$out" "EPOCH_STALE" \
    "the machine that now holds the helm must not be fenced out"

  # The machine that gave it away is read-only, by every route.
  out=$(FM_HOME="$TMP_ROOT/mac" "$ROOT/bin/fm-teardown.sh" live-mac 2>&1 || true)
  assert_contains "$out" "REFUSED" "the old control plane must refuse to clean anything up"
  [ -f "$TMP_ROOT/mac/state/live-mac.meta" ] || fail "a refused cleanup must leave the task alone"
  pass "handover end to end: both tasks supervised from the new machine, nothing restarted, nothing lost"
}

# A queued dispatch cannot travel - it is control-side-only state - so the
# machine giving the helm away must say so, and must stop retrying it.
test_queued_dispatch_is_named_and_then_left_alone() {
  local out
  helm box handover mac >/dev/null 2>&1 || helm mac claim --force >/dev/null
  cat > "$TMP_ROOT/mac/state/waiting.relay-pending" <<EOF
host=box
project=alpha
kind=ship
reason=the screen is locked
EOF
  out=$(helm mac handover box)
  assert_contains "$out" "NOT MOVING: waiting is queued for box" \
    "a queued dispatch must be named as something that does not travel"

  # shellcheck source=bin/fm-relay-lib.sh
  ( . "$ROOT/bin/fm-relay-lib.sh"
    FM_HOME="$TMP_ROOT/mac" FM_RELAY_BIFROST="$STUB/bifrost" \
      fm_relay_pending_emit "$TMP_ROOT/mac" waiting ) > "$TMP_ROOT/pending.out" 2>&1
  [ -s "$TMP_ROOT/pending.out" ] \
    && { cat "$TMP_ROOT/pending.out"; fail "a demoted machine must not keep reporting a dispatch it cannot make"; }
  [ -f "$TMP_ROOT/mac/state/waiting.relay-pending" ] \
    || fail "silence must not mean the queued work was dropped"
  rm -f "$TMP_ROOT/mac/state/waiting.relay-pending"
  pass "queued dispatch: named at handover, then held quietly instead of retried forever"
}

# --- lease invariants --------------------------------------------------------

test_lease_write_is_monotonic_and_fleet_scoped() {
  local out
  rm -rf "$TMP_ROOT/box/cr/helm"
  verb box helm-set "fleet=$FLEET" expect=0 next=5 holder=box by=box >/dev/null
  out=$(verb box helm-set "fleet=$FLEET" expect=5 next=5 holder=mac by=mac)
  assert_contains "$out" "does not advance" "an epoch that stands still must be refused"
  out=$(verb box helm-set "fleet=$FLEET" expect=5 next=4 holder=mac by=mac)
  assert_contains "$out" "does not advance" "an epoch that goes backwards must be refused"
  out=$(verb box helm-set fleet=otherfleet expect=5 next=6 holder=mac by=mac)
  assert_contains "$out" "ERR helmfleet" "a lease write from another fleet must be refused"
  out=$(verb box helm-set "fleet=$FLEET" expect=99 next=100 holder=mac by=mac)
  assert_contains "$out" "ERR helmstale" "a write against the wrong epoch must be refused"
  [ "$(lease_line box)" = "5 box" ] || fail "no refused write may change the lease: $(lease_line box)"
  pass "lease: monotonic, fleet-scoped, and compare-and-swap on every write"
}

test_scripts_parse() {
  local f out rc
  for f in bin/fm-helm.sh bin/fm-helm-lib.sh control-root/verbs/fmr-verb.sh \
    tests/fm-helm-fleetless-probe.sh; do
    out=$(bash -n "$ROOT/$f" 2>&1); rc=$?
    expect_code 0 "$rc" "bash -n $f must parse cleanly (got: $out)"
  done
  pass "helm scripts: bash -n succeeds"
}

test_scripts_parse
test_no_fleet_is_inert
test_host_without_a_lease_is_not_fenced
test_claim_and_handover
test_claim_refuses_to_take_a_held_helm
test_simultaneous_claims_produce_one_winner_and_one_epoch
test_simultaneous_handovers_from_one_holder
test_stale_control_plane_is_refused_by_the_peer
test_missing_epoch_is_refused_too
test_fenced_calls_stay_inside_the_policy_argument_budget
test_read_only_verbs_stay_open_to_a_stale_machine
test_demoted_machine_refuses_both_merges
test_demoted_machine_refuses_to_start_or_steer_work
test_surprise_demotion_is_reported_and_sticky
test_task_list_reports_this_machines_own_work
test_adopt_picks_up_peer_work_without_touching_it
test_adopt_refuses_an_id_collision
test_handover_end_to_end
test_queued_dispatch_is_named_and_then_left_alone
test_lease_write_is_monotonic_and_fleet_scoped
