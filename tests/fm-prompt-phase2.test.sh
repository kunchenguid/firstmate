#!/usr/bin/env bash
set -eu
unset FM_TEST_MODE FM_TEST_RUNNER_PID FM_TEST_RUNNER_ROOT
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "not ok - $*" >&2; exit 1; }

primary=$(python3 "$ROOT/bin/fm-prompt-compile.py" --role primary --harness pi --runtime tmux)
printf '%s' "$primary" | grep -q 'compiled-role: primary' || fail "primary role did not compile"
cat > "$TMP/secondmate-charter.md" <<'EOF'
# Persistent secondmate charter

Scope: prompt runtime verification.
Return findings through the main Firstmate.
EOF
secondmate=$(python3 "$ROOT/bin/fm-prompt-compile.py" --role secondmate --harness pi --runtime tmux --brief "$TMP/secondmate-charter.md")
printf '%s' "$secondmate" | grep -q 'Do not .*communicate with the captain' || fail "secondmate boundary missing"
printf '%s' "$secondmate" | grep -q "captain's only point of contact" && fail "primary rule leaked into secondmate"
printf '%s' "$secondmate" | grep -q 'Scope: prompt runtime verification.' || fail "secondmate charter was not composed"
if python3 "$ROOT/bin/fm-prompt-compile.py" --role primary --harness codex --runtime tmux >/dev/null 2>&1; then
  fail "Codex prompt compilation was accepted"
fi
if python3 "$ROOT/bin/fm-prompt-compile.py" --role secondmate --harness pi --runtime orca >/dev/null 2>&1; then
  fail "unsupported secondmate runtime was accepted"
fi
"$ROOT/bin/fm-prompt-pi-offline-check.sh" >/dev/null

cat > "$TMP/brief.md" <<'EOF'
You are a crewmate: work from the generated instructions.
Delivery contract: mode=local-only
EOF
python3 "$ROOT/bin/fm-prompt-compile.py" --role firstmate-ship --harness pi --runtime tmux --brief "$TMP/brief.md" > "$TMP/ship.prompt"
grep -q 'compiled-role: firstmate-ship' "$TMP/ship.prompt" || fail "ship role did not compile"
cat > "$TMP/leaky.md" <<'EOF'
You are a crewmate. Run `bin/fm-session-start.sh`.
Delivery contract: mode=local-only
EOF
if python3 "$ROOT/bin/fm-prompt-compile.py" --role firstmate-ship --harness pi --runtime tmux --brief "$TMP/leaky.md" >/dev/null 2>&1; then
  fail "primary-only worker leak was accepted"
fi

mkdir -p "$TMP/home/state" "$TMP/other/state"
for file in FIRSTMATE_DISPATCH.md FIRSTMATE_TASK_LIFECYCLE.md FIRSTMATE_BRIEFING.md FIRSTMATE_OPERATIONAL_HOME.md; do cp "$ROOT/$file" "$TMP/home/$file"; done
export FM_ROOT_OVERRIDE="$TMP/home" FM_HOME="$TMP/home" FM_PROMPT_ROLE=primary
if python3 "$ROOT/bin/fm-operation-disclosure.py" consume spawn internal-task -- internal-task repo >/dev/null 2>&1; then
  fail "guarded public mutation accepted an absent receipt"
fi
if FM_TEST_MODE=1 FM_TEST_RUNNER_PID=$$ \
    python3 "$ROOT/bin/fm-operation-disclosure.py" consume spawn internal-task -- internal-task repo >/dev/null 2>&1; then
  fail "caller-controlled test markers bypassed disclosure without the repository runner"
fi
if FM_DISCLOSURE_INTERNAL_CALLER=control-relaunch FM_CONTROL_RELAUNCH_TX=internal \
    python3 "$ROOT/bin/fm-operation-disclosure.py" consume spawn internal-task -- internal-task --relaunch --harness claude >/dev/null 2>&1; then
  fail "caller-controlled internal marker bypassed disclosure without matching process ancestry"
fi
if FM_DISCLOSURE_INTERNAL_CALLER=remote-secondmate-retire \
    python3 "$ROOT/bin/fm-operation-disclosure.py" consume teardown internal-task -- internal-task >/dev/null 2>&1; then
  fail "caller-controlled retirement marker bypassed disclosure without matching process ancestry"
fi
# shellcheck disable=SC2097,SC2098 # ROOT is intentionally expanded by the spoofing child shell.
if ROOT="$ROOT" bash -c 'FM_TEST_MODE=1 FM_TEST_RUNNER_PID=$$ python3 "$ROOT/bin/fm-operation-disclosure.py" consume spawn spoofed -- spoofed repo' "$ROOT/bin/fm-test-run.sh" >/dev/null 2>&1; then
  fail "test-runner path in an ancestor argument bypassed disclosure"
fi
mkdir -p "$TMP/process-spoof"
cat > "$TMP/process-spoof/ps" <<EOF
#!/bin/sh
printf '%s\n' "1 /bin/bash $ROOT/bin/fm-test-run.sh"
EOF
cat > "$TMP/process-spoof/lsof" <<EOF
#!/bin/sh
case "\$*" in
  *'-d cwd'*) printf '%s\n' 'p0' 'n$ROOT' ;;
  *'-d txt'*) printf '%s\n' 'p0' 'n/bin/bash' ;;
esac
EOF
chmod +x "$TMP/process-spoof/ps" "$TMP/process-spoof/lsof"
if PATH="$TMP/process-spoof:$PATH" FM_TEST_MODE=1 FM_TEST_RUNNER_PID=$$ \
    python3 "$ROOT/bin/fm-operation-disclosure.py" consume spawn spoofed -- spoofed repo >/dev/null 2>&1; then
  fail "caller-controlled process tools forged test-runner ancestry"
fi
# shellcheck disable=SC2097,SC2098 # ROOT is intentionally expanded by the spoofing child shell.
if ROOT="$ROOT" bash -c 'FM_DISCLOSURE_INTERNAL_CALLER=batch-spawn FM_SPAWN_NO_GUARD=1 python3 "$ROOT/bin/fm-operation-disclosure.py" consume spawn spoofed -- spoofed repo' "$ROOT/bin/fm-spawn.sh" >/dev/null 2>&1; then
  fail "internal script path in an ancestor argument bypassed disclosure"
fi
mkdir -p "$TMP/spoof/bin"
cat > "$TMP/spoof/bin/fm-test-run.sh" <<EOF
#!/usr/bin/env bash
FM_TEST_MODE=1 FM_TEST_RUNNER_PID=\$\$ python3 "$ROOT/bin/fm-operation-disclosure.py" consume spawn spoofed -- spoofed repo
EOF
chmod +x "$TMP/spoof/bin/fm-test-run.sh"
if (cd "$TMP/spoof" && bash bin/fm-test-run.sh) >/dev/null 2>&1; then
  fail "relative executable-position path from a foreign cwd bypassed disclosure"
fi
cat > "$TMP/spoof/bin/fm-test-run.sh" <<EOF
#!/usr/bin/env bash
FM_TEST_MODE=1 FM_TEST_RUNNER_PID=\$\$ FM_TEST_RUNNER_ROOT="$TMP/spoof" \
  python3 "$ROOT/bin/fm-operation-disclosure.py" consume spawn spoofed -- spoofed repo
EOF
chmod +x "$TMP/spoof/bin/fm-test-run.sh"
if bash "$TMP/spoof/bin/fm-test-run.sh" >/dev/null 2>&1; then
  fail "caller-selected test runner root bypassed disclosure"
fi
cat > "$TMP/relative-runner-probe.py" <<'PY'
import os
import subprocess
import sys

root = sys.argv[1]
environment = os.environ.copy()
environment["FM_TEST_MODE"] = "1"
environment["FM_TEST_RUNNER_PID"] = str(os.getpid())
result = subprocess.run(
    [sys.executable, f"{root}/bin/fm-operation-disclosure.py", "consume", "spawn", "spoofed", "--", "spoofed", "repo"],
    env=environment,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
raise SystemExit(result.returncode)
PY
if (cd "$ROOT" && exec -a bin/fm-test-run.sh python3 "$TMP/relative-runner-probe.py" "$ROOT") >/dev/null 2>&1; then
  fail "relative executable-position path from the repository cwd bypassed disclosure"
fi
if FM_DISCLOSURE_INTERNAL_CALLER=control-relaunch \
    "$ROOT/bin/fm-control.sh" internal-task relaunch --harness claude >/dev/null 2>&1; then
  fail "the public control owner accepted its own caller-controlled internal marker"
fi
mkdir -p "$TMP/home/bin"
cat > "$TMP/home/bin/fm-guard.sh" <<EOF
#!/bin/sh
touch "$TMP/guard-ran"
EOF
chmod +x "$TMP/home/bin/fm-guard.sh"
if "$ROOT/bin/fm-spawn.sh" batch-a=repo-a batch-b=repo-b --mode local-only --yolo off --harness claude >/dev/null 2>&1; then
  fail "production batch spawn accepted an absent outer receipt"
fi
[ ! -e "$TMP/guard-ran" ] || fail "batch spawn ran the watcher guard before refusing an absent receipt"
out=$(python3 "$ROOT/bin/fm-operation-disclosure.py" disclose spawn task-a -- task-a repo --mode local-only --yolo off)
token=${out##*FM_DISCLOSURE_TOKEN=}
[ ${#token} -eq 64 ] || fail "disclosure did not issue a token"
FM_DISCLOSURE_TOKEN=$token python3 "$ROOT/bin/fm-operation-disclosure.py" consume spawn task-a -- task-a repo --mode local-only --yolo off
if FM_DISCLOSURE_TOKEN=$token python3 "$ROOT/bin/fm-operation-disclosure.py" consume spawn task-a -- task-a repo --mode local-only --yolo off >/dev/null 2>&1; then
  fail "consumed disclosure replayed"
fi
out=$(python3 "$ROOT/bin/fm-operation-disclosure.py" --ttl 17 disclose spawn task-ttl -- task-ttl repo)
ttl_token=${out##*FM_DISCLOSURE_TOKEN=}
FM_DISCLOSURE_TOKEN=$ttl_token python3 "$ROOT/bin/fm-operation-disclosure.py" consume spawn task-ttl -- task-ttl repo \
  || fail "a valid non-default disclosure ttl was reconstructed with the consumer default"
out=$(FM_STATE_OVERRIDE="$TMP/receipt-state" FM_DATA_OVERRIDE="$TMP/receipt-data" \
  FM_CONFIG_OVERRIDE="$TMP/receipt-config" FM_PROJECTS_OVERRIDE="$TMP/receipt-projects" \
  python3 "$ROOT/bin/fm-operation-disclosure.py" disclose spawn task-paths -- task-paths repo)
path_token=${out##*FM_DISCLOSURE_TOKEN=}
if FM_STATE_OVERRIDE="$TMP/other-state" FM_DATA_OVERRIDE="$TMP/receipt-data" \
    FM_CONFIG_OVERRIDE="$TMP/receipt-config" FM_PROJECTS_OVERRIDE="$TMP/receipt-projects" \
    FM_DISCLOSURE_TOKEN=$path_token python3 "$ROOT/bin/fm-operation-disclosure.py" consume spawn task-paths -- task-paths repo >/dev/null 2>&1; then
  fail "disclosure accepted a changed mutation root"
fi
FM_STATE_OVERRIDE="$TMP/receipt-state" FM_DATA_OVERRIDE="$TMP/receipt-data" \
  FM_CONFIG_OVERRIDE="$TMP/receipt-config" FM_PROJECTS_OVERRIDE="$TMP/receipt-projects" \
  FM_DISCLOSURE_TOKEN=$path_token python3 "$ROOT/bin/fm-operation-disclosure.py" consume spawn task-paths -- task-paths repo \
  || fail "disclosure rejected its bound mutation roots"
out=$(python3 "$ROOT/bin/fm-operation-disclosure.py" disclose control task-relaunch -- task-relaunch relaunch --note continue)
control_token=${out##*FM_DISCLOSURE_TOKEN=}
FM_DISCLOSURE_TOKEN=$control_token python3 "$ROOT/bin/fm-operation-disclosure.py" consume control task-relaunch -- task-relaunch relaunch --note continue
out=$(FM_DISCLOSURE_TOKEN=$control_token python3 "$ROOT/bin/fm-operation-disclosure.py" handoff control-relaunch task-relaunch -- task-relaunch --relaunch --harness claude)
spawn_token=${out##*FM_DISCLOSURE_TOKEN=}
FM_DISCLOSURE_TOKEN=$spawn_token python3 "$ROOT/bin/fm-operation-disclosure.py" consume spawn task-relaunch -- task-relaunch --relaunch --harness claude
if FM_DISCLOSURE_TOKEN=$control_token python3 "$ROOT/bin/fm-operation-disclosure.py" handoff control-relaunch task-relaunch -- task-relaunch --relaunch --harness claude >/dev/null 2>&1; then
  fail "control relaunch disclosure issued more than one internal handoff"
fi
out=$(python3 "$ROOT/bin/fm-operation-disclosure.py" disclose control task-race -- task-race relaunch --note continue)
race_token=${out##*FM_DISCLOSURE_TOKEN=}
FM_DISCLOSURE_TOKEN=$race_token python3 "$ROOT/bin/fm-operation-disclosure.py" consume control task-race -- task-race relaunch --note continue
set +e
FM_DISCLOSURE_TOKEN=$race_token python3 "$ROOT/bin/fm-operation-disclosure.py" handoff control-relaunch task-race -- task-race --relaunch --harness claude >"$TMP/race-1" 2>/dev/null &
race_pid_1=$!
FM_DISCLOSURE_TOKEN=$race_token python3 "$ROOT/bin/fm-operation-disclosure.py" handoff control-relaunch task-race -- task-race --relaunch --harness claude >"$TMP/race-2" 2>/dev/null &
race_pid_2=$!
wait "$race_pid_1"; race_rc_1=$?
wait "$race_pid_2"; race_rc_2=$?
set -e
[ $(((race_rc_1 == 0) + (race_rc_2 == 0))) -eq 1 ] \
  || fail "concurrent control relaunch did not issue exactly one handoff"
if FM_DISCLOSURE_TOKEN=$race_token python3 "$ROOT/bin/fm-operation-disclosure.py" handoff control-relaunch task-race -- task-race --relaunch --harness claude >/dev/null 2>&1; then
  fail "losing concurrent handoff restored a consumed source receipt"
fi
out=$(python3 "$ROOT/bin/fm-operation-disclosure.py" disclose control task-exit -- task-exit exit)
exit_token=${out##*FM_DISCLOSURE_TOKEN=}
FM_DISCLOSURE_TOKEN=$exit_token python3 "$ROOT/bin/fm-operation-disclosure.py" consume control task-exit -- task-exit exit
if FM_DISCLOSURE_TOKEN=$exit_token python3 "$ROOT/bin/fm-operation-disclosure.py" handoff control-relaunch task-exit -- task-exit --relaunch --harness claude >/dev/null 2>&1; then
  fail "non-relaunch control disclosure authorized an internal spawn"
fi
out=$(python3 "$ROOT/bin/fm-operation-disclosure.py" disclose spawn task-a -- task-a repo)
token=${out##*FM_DISCLOSURE_TOKEN=}
if FM_DISCLOSURE_TOKEN=$token python3 "$ROOT/bin/fm-operation-disclosure.py" consume spawn task-b -- task-b repo >/dev/null 2>&1; then
  fail "cross-task disclosure was accepted"
fi
if FM_HOME="$TMP/other" FM_DISCLOSURE_TOKEN=$token python3 "$ROOT/bin/fm-operation-disclosure.py" consume spawn task-a -- task-a repo >/dev/null 2>&1; then
  fail "cross-home disclosure was accepted"
fi
printf '\nchanged\n' >> "$TMP/home/FIRSTMATE_DISPATCH.md"
if FM_DISCLOSURE_TOKEN=$token python3 "$ROOT/bin/fm-operation-disclosure.py" consume spawn task-a -- task-a repo >/dev/null 2>&1; then
  fail "stale instruction disclosure was accepted"
fi
# Restore the owner, then prove expiry independently of content mismatch.
sed -i.bak '$d' "$TMP/home/FIRSTMATE_DISPATCH.md" && rm "$TMP/home/FIRSTMATE_DISPATCH.md.bak"
out=$(python3 "$ROOT/bin/fm-operation-disclosure.py" --ttl 1 disclose spawn task-expired -- task-expired repo)
expired=${out##*FM_DISCLOSURE_TOKEN=}
sleep 2
if FM_DISCLOSURE_TOKEN=$expired python3 "$ROOT/bin/fm-operation-disclosure.py" consume spawn task-expired -- task-expired repo >/dev/null 2>&1; then
  fail "expired disclosure was accepted"
fi

# The production merge owner refuses before invoking Git when disclosure is absent.
mkdir -p "$TMP/fakebin" "$TMP/home/data" "$TMP/home/projects"
cat > "$TMP/fakebin/git" <<EOF
#!/bin/sh
echo called >> "$TMP/git-called"
exit 1
EOF
chmod +x "$TMP/fakebin/git"
if PATH="$TMP/fakebin:$PATH" FM_DISCLOSURE_TOKEN='' "$ROOT/bin/fm-merge-local.sh" task-a >/dev/null 2>&1; then
  fail "merge owner accepted a missing disclosure"
fi
[ ! -e "$TMP/git-called" ] || fail "merge owner performed Git work before disclosure"

echo "ok phase-two role compilation, leak refusal, compact discovery inputs, and guarded disclosure receipts"
