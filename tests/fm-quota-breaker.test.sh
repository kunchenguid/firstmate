#!/usr/bin/env bash
# bin/fm-quota-breaker.sh: the quota circuit breaker.
#
# What these pin, through the executable interface the watcher calls:
#   1. classify: each verified provider refusal maps to its class from the text
#      the harness renders, a refusal the worker scrolled past does not trip,
#      and a request rate limit trips only as a run, never once.
#   2. scan: off without config/quota-breaker; with it, one line per tripped
#      ship or scout naming the task and class, never a second mate; a repeat
#      sweep stays quiet, while a relaunched incarnation that hits the same wall
#      is reported afresh.
#   3. The watcher's check sweep runs the scan only with the gate present and
#      queues each reported worker as its own `check: quota-breaker` wake.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BREAKER="$ROOT/bin/fm-quota-breaker.sh"
TMP_ROOT=$(fm_test_tmproot fm-quota-breaker)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
trap 'rm -rf -- "$TMP_ROOT"' EXIT

classify() {  # <pane-text> [repeats]
  printf '%s\n' "$1" | bash "$BREAKER" classify ${2:+"$2"}
}

test_classify_each_provider_refusal() {
  local class text got
  while IFS='|' read -r class text; do
    [ -n "$class" ] || continue
    got=$(classify "$(printf 'working on it\n%s\n\n────\n' "$text")")
    [ "${got%%$'\t'*}" = "$class" ] || fail "'$text' should classify as $class, got: '$got'"
    text=${text#"${text%%[![:space:]]*}"}
    assert_contains "$got" "${text:0:20}" "the matched row should be carried for $class"
  done <<'EOF'
zai-1308|Error: 429: {"code":"1308","message":"Usage limit reached for 5 hour. Your limit will reset at 2026-11-11 18:00:00"}
zai-1310|Error: 429: {"code":"1310","message":"Weekly/Monthly Limit Exhausted. Your limit will reset at 2026-11-14 09:00:00"}
antigravity-429|Error: Quota reached. Please wait 3h39m45s. Next: switch models or try again after reset.
antigravity-429|Error: Quota reached. Next: switch models or retry later.
antigravity-429|Error: 429 RESOURCE_EXHAUSTED: Resource has been exhausted (e.g. check quota).
codex-usage-limit|Codex error: The usage limit has been reached
codex-usage-limit|■ You've hit your usage limit. Upgrade to Pro or try again later.
claude-usage-limit|  ⎿  Claude usage limit reached. Your limit will reset at 3pm.
claude-usage-limit|  ⎿  5-hour limit reached ∙ resets 3pm
claude-usage-limit|  ⎿  You've hit your limit · resets 4pm
EOF
  pass "fm-quota-breaker classify: every verified provider refusal maps to its class"
}

test_classify_ignores_recovered_and_single_rate_limits() {
  local got rows i
  rows='Error: 429: {"code":"1308","message":"Usage limit reached for 5 hour."}'
  for i in $(seq 1 20); do rows="$rows"$'\n'"progress line $i"; done
  got=$(classify "$rows")
  [ -z "$got" ] || fail "a refusal scrolled past 15 rows of later output must not trip, got: $got"

  rows=
  for i in 1 2 3 4; do rows="$rows"$'\n''Error: 429: {"code":"1302","message":"Rate limit reached for requests"}'; done
  for i in $(seq 1 15); do rows="$rows"$'\n'"progress line $i"; done
  rows="$rows"$'\n''Error: 429: {"code":"1302","message":"Rate limit reached for requests"}'
  got=$(classify "$rows")
  [ -z "$got" ] || fail "stale request rate limits outside the bottom window must not trip, got: $got"

  rows=
  for i in 1 2 3 4; do rows="$rows"$'\n''Error: 429: {"code":"1302","message":"Rate limit reached for requests"}'; done
  got=$(classify "$rows")
  [ -z "$got" ] || fail "four request rate limits are retries under the default of five, got: $got"
  rows="$rows"$'\n''Error: 429: {"code":"1302","message":"Rate limit reached for requests"}'
  got=$(classify "$rows")
  [ "${got%%$'\t'*}" = zai-1302 ] || fail "five request rate limits should trip the breaker, got: $got"
  assert_contains "$got" "(x5)" "the rate-limit trip should say how many it saw"
  got=$(classify "$rows" 6)
  [ -z "$got" ] || fail "a configured threshold of six must not trip on five, got: $got"

  got=$(classify $'Usage: tracking limits in the docs\nrate limiting explained')
  [ -z "$got" ] || fail "ordinary text about limits must not trip, got: $got"
  pass "fm-quota-breaker classify: a recovered refusal and a single rate limit do not trip"
}

# A tmux stub whose capture-pane renders $FM_FAKE_DIR/pane.<window>.
make_case() {  # <name> -> case dir
  local dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/fakebin" "$dir/fake"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
target=
prev=
for a in "$@"; do
  [ "$prev" = -t ] && target=$a
  prev=$a
done
case "${1:-}" in
  capture-pane) cat "$FM_FAKE_DIR/pane.${target##*:}" 2>/dev/null; exit 0 ;;
  display-message) printf 'pi\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/tmux"
  printf '%s\n' "$dir"
}

add_task() {  # <case> <id> <kind> <pane-text> [spawn-gen]
  local dir=$1 id=$2 kind=$3
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "harness=pi"
    echo "model=zai/glm-5.3-flash"
    echo "kind=$kind"
    echo "spawn_gen=${5:-s1}"
  } > "$dir/home/state/$id.meta"
  printf '%s\n' "$4" > "$dir/fake/pane.fm-$id"
}

scan() {  # <case>
  env PATH="$1/fakebin:$PATH" FM_HOME="$1/home" FM_FAKE_DIR="$1/fake" FM_BACKEND=tmux \
    bash "$BREAKER" scan 2>&1
}

test_scan_reports_once_per_incarnation() {
  local dir out
  dir=$(make_case scan)
  add_task "$dir" t1 ship 'Error: 429: {"code":"1308","message":"Usage limit reached for 5 hour."}'
  add_task "$dir" t2 scout 'all good, still working'
  add_task "$dir" sm1 secondmate 'Error: 429: {"code":"1308","message":"Usage limit reached for 5 hour."}'

  out=$(scan "$dir")
  [ -z "$out" ] || fail "the breaker must stay off without config/quota-breaker, got: $out"

  : > "$dir/home/config/quota-breaker"
  out=$(scan "$dir")
  assert_contains "$out" "quota-breaker t1 zai-1308 harness=pi model=zai/glm-5.3-flash:" \
    "a stalled ship should be reported with its task, class, and profile"
  [ "$(printf '%s\n' "$out" | grep -c '^quota-breaker ')" = 1 ] \
    || fail "only the stalled ship should be reported, not a healthy scout or a second mate, got: $out"

  out=$(scan "$dir")
  [ -z "$out" ] || fail "the same stall must not be reported twice inside the realert window, got: $out"

  # A relaunch records a new spawn generation; the replacement hitting the same
  # wall is news.
  sed -i.bak 's/^spawn_gen=s1$/spawn_gen=s2/' "$dir/home/state/t1.meta"
  out=$(scan "$dir")
  assert_contains "$out" "quota-breaker t1 zai-1308" "a relaunched incarnation hitting the same wall should be reported"

  printf 'realert-seconds=0\n' > "$dir/home/config/quota-breaker"
  out=$(scan "$dir")
  [ -z "$out" ] || fail "a zero realert value is unusable and must keep the default window, got: $out"
  pass "fm-quota-breaker scan: one report per stalled ship or scout incarnation, off without its config"
}

run_watcher_once() {  # <case>
  local dir=$1
  printf '#!/usr/bin/env bash\nprintf "stop-cycle\\n"\n' > "$dir/home/state/z-stop.check.sh"
  chmod 0700 "$dir/home/state/z-stop.check.sh"
  FM_HOME="$dir/home" "$ROOT/bin/fm-check-register.sh" z-stop >/dev/null || fail "could not register the stop check"
  timeout 60 env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" FM_BACKEND=tmux \
    FM_CHECK_INTERVAL=0 FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
    bash "$ROOT/bin/fm-watch.sh" > "$dir/watch.out" 2> "$dir/watch.err"
}

test_watcher_sweep_queues_one_wake_per_worker() {
  local dir rc
  dir=$(make_case watch-off)
  add_task "$dir" t1 ship 'Error: 429: {"code":"1308","message":"Usage limit reached for 5 hour."}'
  run_watcher_once "$dir"; rc=$?
  [ "$rc" -eq 0 ] || fail "the watcher failed without the gate: $(cat "$dir/watch.err")"
  ! grep -F 'check: quota-breaker:' "$dir/home/state/.wake-queue" >/dev/null 2>&1 \
    || fail "the watcher queued a breaker wake without config/quota-breaker"

  dir=$(make_case watch-on)
  : > "$dir/home/config/quota-breaker"
  add_task "$dir" t1 ship 'Error: 429: {"code":"1308","message":"Usage limit reached for 5 hour."}'
  add_task "$dir" t2 scout 'Codex error: The usage limit has been reached'
  run_watcher_once "$dir"; rc=$?
  [ "$rc" -eq 0 ] || fail "the watcher failed with the gate: $(cat "$dir/watch.err")"
  grep -F 'check: quota-breaker: t1 zai-1308 harness=pi' "$dir/home/state/.wake-queue" >/dev/null \
    || fail "the stalled ship was not queued as its own wake: $(cat "$dir/home/state/.wake-queue" 2>/dev/null)"
  grep -F 'check: quota-breaker: t2 codex-usage-limit' "$dir/home/state/.wake-queue" >/dev/null \
    || fail "the stalled scout was not queued as its own wake: $(cat "$dir/home/state/.wake-queue" 2>/dev/null)"
  pass "fm-quota-breaker: the watcher sweep queues one wake per stalled worker, only with the gate present"
}

test_classify_each_provider_refusal
test_classify_ignores_recovered_and_single_rate_limits
test_scan_reports_once_per_incarnation
test_watcher_sweep_queues_one_wake_per_worker
