#!/usr/bin/env bash
# Live Pi composer and Grok non-typing recovery guard in a helper-owned Herdr lab.
# FM_CONTROL_COMPOSER_LIVE=1 opts in: Grok and the replacement Pi submit a
# tiny prompt. FM_CONTROL_GROK_REQUIRE_LIMIT=1 requires the real quota menu,
# rather than reporting that this account did not expose that optional case.
# All adapter calls pass through the same session-checking lab wrapper.
. "$(dirname "${BASH_SOURCE[0]}")/environment.sh"
fm_test_sanitize_environment
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_CONTROL_COMPOSER_LIVE herdr jq

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name control-composer)
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-control-composer.XXXXXX")
SCRATCH=$(cd "$SCRATCH" && pwd -P)
cleanup() {
  local rc=$?
  trap - EXIT
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" || rc=1
  rm -rf "$SCRATCH"
  exit "$rc"
}
trap cleanup EXIT
"$LAB_HELPER" provision "$SESSION"
mkdir -p "$SCRATCH/bin" "$SCRATCH/home/state" "$SCRATCH/home/data" "$SCRATCH/project"
cat > "$SCRATCH/bin/herdr" <<EOF
#!/usr/bin/env bash
set -eu
args=("\$@")
n=\${#args[@]}
[ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ] \\
  && [ "\${args[\$((n-1))]}" = "$SESSION" ] || exit 98
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]:0:\$((n-2))}"
EOF
chmod +x "$SCRATCH/bin/herdr"
export PATH="$SCRATCH/bin:$ORIGINAL_PATH"
lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
# shellcheck source=bin/fm-backend.sh
. "$ROOT/bin/fm-backend.sh"
git -C "$SCRATCH/project" init -q
printf '# Recovery lab\n' > "$SCRATCH/project/README.md"
git -C "$SCRATCH/project" add README.md
git -C "$SCRATCH/project" -c user.name=Tests -c user.email=tests@example.invalid commit -qm initial
git -C "$SCRATCH/project" worktree add -q -b control-lab "$SCRATCH/worktree"
HERDR_VERSION=$(lab status --json | jq -r '.client.version')
CHECKED=0

start_case() { # <id> <harness> <command>
  local id=$1 harness=$2 command=$3 ws
  ws=$(lab workspace create --cwd "$SCRATCH/worktree" --label "fm-$id" --no-focus)
  PANE=$(printf '%s' "$ws" | jq -er '.result.root_pane.pane_id')
  TARGET="$SESSION:$PANE"
  mkdir -p "$SCRATCH/home/data/$id"
  printf '# Task\n## Captain\047s intent\nReply exactly CONTROL_READY. Do not use tools or modify files.\n\n## Firstmate spec\nThis is an isolated recovery test. Reply once without any tools.\n' > "$SCRATCH/home/data/$id/brief.md"
  {
    printf 'window=%s\nendpoint_task_id=%s\n' "$TARGET" "$id"
    printf 'project=%s\nworktree=%s\n' "$SCRATCH/project" "$SCRATCH/worktree"
    printf 'harness=%s\nkind=scout\nmode=local-only\nyolo=off\nbackend=herdr\n' "$harness"
    printf 'herdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' \
      "$SESSION" "${PANE%%:*}" "${PANE%%:*}:t1" "$PANE"
  } > "$SCRATCH/home/state/$id.meta"
  lab pane run "$PANE" "$command" >/dev/null
}

wait_composer() { # <expected>
  local i=0 actual
  while [ "$i" -lt 45 ]; do
    actual=$(fm_backend_composer_state herdr "$TARGET")
    [ "$actual" != "$1" ] || return 0
    i=$((i + 1)); sleep 1
  done
  lab pane read "$PANE" --source visible >&2
  fail "composer expected $1, got $actual [$VERSION; $HERDR_VERSION]"
}

control() {
  env FM_HOME="$SCRATCH/home" FM_SPAWN_NO_GUARD=1 FM_CONTROL_EXIT_WAIT=10 \
    FM_CONTROL_LAUNCH_WAIT=45 "$ROOT/bin/fm-control.sh" "$@"
}

if command -v pi >/dev/null 2>&1; then
  VERSION=$(pi --version)
  for mode in configured stock; do
    cmd='pi --offline --no-session'
    [ "$mode" != stock ] || cmd="$cmd --no-extensions"
    start_case "$mode" pi "$cmd"
    wait_composer empty
    # Proven empty before inserting a deliberately unsubmitted multiline draft.
    lab pane send-text "$PANE" $'CONTROL_DRAFT\nsecond row' >/dev/null
    wait_composer pending
    if control "$mode" exit > "$SCRATCH/refusal.log" 2>&1; then
      fail "Pi $mode draft was not preserved [$VERSION]"
    fi
    [ "$(fm_backend_agent_state herdr "$TARGET")" = alive ] || fail "pending Pi exited"
    # Pi's documented clear key, not a submitted command.
    lab pane send-keys "$PANE" ctrl+c >/dev/null
    wait_composer empty
    control "$mode" exit
    [ "$(fm_backend_agent_state herdr "$TARGET")" = dead ] || fail "Pi exit lacked death proof"
    control "$mode" exit | grep -q '^already-stopped ' || fail "Pi exit is not idempotent"
    pass "live Pi $mode $VERSION: empty, multiline pending refusal, verified exit, idempotence"
    CHECKED=$((CHECKED + 1))
  done
else
  printf '# pi absent; Pi composer not verified\n'
fi

if command -v grok >/dev/null 2>&1; then
  VERSION=$(grok --version)
  start_case grok grok 'grok --always-approve "Reply OK without using tools."'
  i=0
  native=''
  while [ "$i" -lt 60 ]; do
    native=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
    screen=$(lab pane read "$PANE" --source visible)
    if [ "$native" = blocked ] && [[ "$screen" = *'weekly limit'* ]]; then break; fi
    if [ "$i" -ge 8 ] && { [ "$native" = idle ] || [ "$native" = 'done' ]; }; then break; fi
    i=$((i + 1)); sleep 1
  done
  if [ "$native" = blocked ] && [[ "$screen" = *'weekly limit'* ]]; then
    [ "$(fm_backend_composer_state herdr "$TARGET")" = unknown ] || fail "Grok limit menu became a composer"
    # Preserve dirty work through the actual stop-and-replacement transaction.
    printf 'preserve me\n' > "$SCRATCH/worktree/draft.txt"
    before=$(git -C "$SCRATCH/worktree" rev-parse HEAD)
    if command -v pi >/dev/null 2>&1; then
      control grok relaunch --harness pi --effort low --note 'The former worker reached its quota. Reply CONTROL_READY without tools.'
      [ "$(fm_backend_agent_state herdr "$TARGET")" = alive ] || fail "replacement not alive"
      [ "$(git -C "$SCRATCH/worktree" rev-parse HEAD)" = "$before" ] || fail "relaunch changed branch"
      [ "$(cat "$SCRATCH/worktree/draft.txt")" = 'preserve me' ] || fail "relaunch lost dirty work"
      wait_composer empty
      control grok exit
      pass "live Grok $VERSION: real weekly-limit menu replaced by Pi without human input; dirty work preserved"
    else
      control grok exit
      [ "$(fm_backend_agent_state herdr "$TARGET")" = dead ] || fail "Grok quit lacks death proof"
      pass "live Grok $VERSION: real weekly-limit menu stopped without typing"
    fi
    CHECKED=$((CHECKED + 1))
  else
    [ "${FM_CONTROL_GROK_REQUIRE_LIMIT:-0}" != 1 ] || fail "Grok $VERSION did not expose its weekly-limit menu"
    printf '# Grok %s: real quota menu unavailable; fallback not verified on this account\n' "$VERSION"
  fi
else
  printf '# grok absent; non-typing recovery not verified\n'
  [ "${FM_CONTROL_GROK_REQUIRE_LIMIT:-0}" != 1 ] || fail "Grok required but absent"
fi
[ "$CHECKED" -gt 0 ] || fail "no live harness was verified"
