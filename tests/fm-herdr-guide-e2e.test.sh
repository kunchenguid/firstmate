#!/usr/bin/env bash
# Opt-in real-Herdr acceptance for docs/herdr-backend.md.
# It installs the stable binary into an isolated prefix, provisions only a
# generated non-default lab session, and exercises the documented Firstmate
# lifecycle without touching the live default session.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "${FM_RUN_HERDR_GUIDE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_RUN_HERDR_GUIDE_E2E=1 to verify the canonical Herdr guide"
  exit 0
fi

for tool in curl git jq lsof ps; do
  command -v "$tool" >/dev/null 2>&1 || fail "$tool is required for the Herdr guide E2E"
done

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$LAB_HELPER" name herdr-guide-e2e)
TMP_ROOT=$(mktemp -d /tmp/fh.XXXXXX)
XDG_CONFIG_HOME="$TMP_ROOT/c"
export XDG_CONFIG_HOME
FM_HERDR_LAB_STATE_DIR="$TMP_ROOT/s"
export FM_HERDR_LAB_STATE_DIR
INSTALL_BIN="$TMP_ROOT/install/bin"
HOME_ROOT="$TMP_ROOT/home"
PROJECT="$TMP_ROOT/project"
WORKTREE="$TMP_ROOT/worktree"
TREEBIN="$TMP_ROOT/treebin"
SHIMBIN="$TMP_ROOT/shimbin"
ORIGINAL_PATH=$PATH
ID=herdr-guide-e2e
CLEANED=0

cleanup() {
  local rc=$?
  trap - EXIT
  if [ "$CLEANED" != 1 ]; then
    if "$LAB_HELPER" teardown "$SESSION"; then
      CLEANED=1
    else
      rc=1
      echo "Herdr guide E2E retained failed-cleanup evidence at $TMP_ROOT" >&2
    fi
  fi
  if [ "$CLEANED" = 1 ]; then
    rm -rf "$TMP_ROOT"
  fi
  exit "$rc"
}
trap cleanup EXIT

mkdir -p "$INSTALL_BIN" "$HOME_ROOT/data/$ID" "$HOME_ROOT/state" \
  "$HOME_ROOT/config" "$HOME_ROOT/projects" "$PROJECT" "$TREEBIN" "$SHIMBIN" \
  "$FM_HERDR_LAB_STATE_DIR"

# This is the clean Linux/macOS install command documented by Herdr and by the
# canonical Firstmate guide. HERDR_INSTALL_DIR keeps the verification isolated.
curl -fsSL https://herdr.dev/install.sh | HERDR_INSTALL_DIR="$INSTALL_BIN" sh >/dev/null
PATH="$INSTALL_BIN:$TREEBIN:$ORIGINAL_PATH"
export PATH
[ "$(command -v herdr)" = "$INSTALL_BIN/herdr" ] || fail "isolated Herdr install is not first on PATH"

git -C "$PROJECT" init -q -b main
git -C "$PROJECT" config user.email guide-e2e@example.invalid
git -C "$PROJECT" config user.name 'Firstmate Guide E2E'
touch "$PROJECT/README.md"
git -C "$PROJECT" add README.md
git -C "$PROJECT" commit -q -m init
git -C "$PROJECT" worktree add -q -b guide-e2e "$WORKTREE"
printf '# Herdr guide E2E\n\nRemain idle while the lifecycle is verified.\n' > "$HOME_ROOT/data/$ID/brief.md"

cat > "$TREEBIN/treehouse" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
  get)
    cd '$WORKTREE'
    exec bash --noprofile --norc
    ;;
  return)
    target=
    for arg in "\$@"; do target=\$arg; done
    git -C '$PROJECT' worktree remove --force "\$target"
    ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$TREEBIN/treehouse"

cat > "$SHIMBIN/herdr" <<EOF
#!/usr/bin/env bash
set -euo pipefail
helper='$LAB_HELPER'
session='$SESSION'
real_path='$PATH'
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "\$session" ] || exit 97
  args=("\${args[@]:0:\$((n-2))}")
else
  [ "\${HERDR_SESSION:-}" = "\$session" ] || exit 98
fi
PATH="\$real_path" exec "\$helper" run "\$session" "\${args[@]}"
EOF
chmod +x "$SHIMBIN/herdr"

INITIAL_BASELINE=$("$LAB_HELPER" run "$SESSION" session list --json | jq -S -c --arg session "$SESSION" \
  '{sessions:[.sessions[] | select(.name != $session) | {default,name,running,socket_path}]}')
BASELINE_KIND=$(printf '%s' "$INITIAL_BASELINE" | jq -r 'if (.sessions | length) == 0 then "absent" else "default" end')
"$LAB_HELPER" provision "$SESSION"
STATUS=$("$LAB_HELPER" run "$SESSION" status --json)
VERSION=$(printf '%s' "$STATUS" | jq -r '.client.version')
PROTOCOL=$(printf '%s' "$STATUS" | jq -r '.client.protocol')
RUNNING=$(printf '%s' "$STATUS" | jq -r '.server.running')
[ "$RUNNING" = true ] || fail "the isolated Herdr server is not ready"
[ "$PROTOCOL" -ge 14 ] || fail "Herdr protocol $PROTOCOL is below the supported minimum 14"

DEFAULT_BACKEND=$(FM_HOME="$HOME_ROOT" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_name' _ "$ROOT")
[ "$DEFAULT_BACKEND" = herdr ] || fail "an unconfigured Firstmate home did not select Herdr"
printf 'herdr\n' > "$HOME_ROOT/config/backend"
CONFIGURED_BACKEND=$(FM_HOME="$HOME_ROOT" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_name' _ "$ROOT")
[ "$CONFIGURED_BACKEND" = herdr ] || fail "config/backend=herdr did not select Herdr"
rm -f "$HOME_ROOT/config/backend"

spawn_task() {
  PATH="$SHIMBIN:$PATH" FM_HOME="$HOME_ROOT" HERDR_SESSION="$SESSION" FM_GATE_REFUSE_BYPASS=1 \
    "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJECT" --scout --harness 'bash --noprofile --norc'
}

spawn_task >/dev/null
META="$HOME_ROOT/state/$ID.meta"
[ -f "$META" ] || fail "spawn did not write task metadata"
assert_no_grep '^backend=' "$META" "default Herdr metadata unexpectedly wrote backend="
TARGET=$(sed -n 's/^window=//p' "$META")
PANE=${TARGET#*:}
"$LAB_HELPER" run "$SESSION" pane get "$PANE" >/dev/null

SEND_TOKEN=HERDR_GUIDE_SEND_OK
PATH="$SHIMBIN:$PATH" FM_HOME="$HOME_ROOT" FM_GATE_REFUSE_BYPASS=1 \
  "$ROOT/bin/fm-send.sh" "$ID" "echo $SEND_TOKEN" >/dev/null
for _ in $(seq 1 40); do
  if "$LAB_HELPER" run "$SESSION" pane read "$PANE" --source recent --lines 200 2>/dev/null | grep -q "$SEND_TOKEN"; then
    break
  fi
  sleep 0.25
done
"$LAB_HELPER" run "$SESSION" pane read "$PANE" --source recent --lines 200 | grep -q "$SEND_TOKEN" \
  || fail "the spawned task did not receive the steer"

date +%s > "$HOME_ROOT/state/.afk"
WATCH_OUT="$TMP_ROOT/watch.out"
PATH="$SHIMBIN:$PATH" FM_STATE_OVERRIDE="$HOME_ROOT/state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$WATCH_OUT" &
WATCH_PID=$!
sleep 0.5
printf 'working: guarded Herdr guide E2E\n' > "$HOME_ROOT/state/$ID.status"
for _ in $(seq 1 40); do
  kill -0 "$WATCH_PID" 2>/dev/null || break
  sleep 0.25
done
wait "$WATCH_PID" || fail "watcher did not exit after the task status wake"
grep -F "signal: $HOME_ROOT/state/$ID.status" "$WATCH_OUT" >/dev/null \
  || fail "watcher did not surface the task status wake"
rm -f "$HOME_ROOT/state/.afk"

# The guarded stop is the only deliberate mid-run lifecycle operation.
"$LAB_HELPER" stop "$SESSION"
"$LAB_HELPER" provision "$SESSION"
RESTARTED=$("$LAB_HELPER" run "$SESSION" status --json | jq -r '.server.running')
[ "$RESTARTED" = true ] || fail "the named lab server did not recover after restart"
spawn_task >/dev/null
RECOVERY_TARGET=$(sed -n 's/^window=//p' "$META")
[ -n "$RECOVERY_TARGET" ] || fail "recovery spawn did not refresh the endpoint metadata"

touch "$HOME_ROOT/data/$ID/report.md"
PATH="$SHIMBIN:$PATH" FM_HOME="$HOME_ROOT" FM_GATE_REFUSE_BYPASS=1 \
  "$ROOT/bin/fm-teardown.sh" "$ID" >/dev/null
[ ! -e "$META" ] || fail "production teardown left task metadata behind"

LAB_TEARDOWN_STATUS=0
LAB_TEARDOWN_OUTPUT=$("$LAB_HELPER" teardown "$SESSION" 2>&1) || LAB_TEARDOWN_STATUS=$?
[ "$LAB_TEARDOWN_STATUS" -ne 0 ] || fail "Herdr 0.7.3 unexpectedly supplied an atomic delete proof"
printf '%s' "$LAB_TEARDOWN_OUTPUT" | grep -F "exposes no atomic conditional-delete proof" >/dev/null \
  || fail "guarded lab teardown omitted the missing atomic-proof diagnostic"
LAB_STATE=$($LAB_HELPER run "$SESSION" session list --json)
[ "$(printf '%s' "$LAB_STATE" | jq -r --arg session "$SESSION" '.sessions[] | select(.name == $session) | .running')" = false ] \
  || fail "failed-closed lab teardown did not leave the named session stopped"
[ -f "$FM_HERDR_LAB_STATE_DIR/$SESSION.fleet-state.json" ] \
  || fail "failed-closed lab teardown discarded its ownership evidence"
FINAL_BASELINE=$("$LAB_HELPER" run "$SESSION" session list --json | jq -S -c --arg session "$SESSION" \
  '{sessions:[.sessions[] | select(.name != $session) | {default,name,running,socket_path}]}')
[ "$FINAL_BASELINE" = "$INITIAL_BASELINE" ] || fail "guarded lab teardown changed the captured default fleet"
CLEANED=1

printf 'HERDR_GUIDE_E2E_OK version=%s protocol=%s session=%s baseline=%s default=herdr configured=herdr readiness=ok spawn=ok steer=ok watcher=signal restart=recovered teardown=ok lab_teardown=refused-no-atomic-proof\n' \
  "$VERSION" "$PROTOCOL" "$SESSION" "$BASELINE_KIND"
