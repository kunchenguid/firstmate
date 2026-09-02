#!/usr/bin/env bash
# tests/fm-herdr-agent-free-proof-live-e2e.test.sh - opt-in drift guard proving
# no INSTALLED harness, while genuinely running in a Herdr pane, can be
# mistaken for an agent-free bare idle shell.
#
# Why this file exists: the Herdr liveness classifier settles its negative
# verdict from `pane process-info` - the pane must provably hold one lone bare
# idle shell before a reported registration is treated as stale
# (bin/backends/herdr.sh, fm_backend_herdr_pane_agent_state). That proof reads
# a process name and an argv0 that each harness vendor controls and can change
# without notice, so a stub can only confirm the assumption already written
# into the stub. A false agent-free verdict is the one outcome that could
# launch a replacement onto a live worker's local copy, which is exactly the
# direction this guard watches.
#
# The portable counterpart in tests/fm-backend-herdr.test.sh pins the
# classifier logic in CI with real processes and no harness, and
# tests/fm-control-herdr-smoke.test.sh pins the control plane's use of it on
# the required real-Herdr lane. Run this guard after any harness upgrade and
# before trusting refreshed per-harness evidence.
#
# Each harness is launched bare, with no prompt, so this consumes no model
# tokens. Standard CI has neither harness binaries nor credentials, so it is
# opt-in and on-demand.
#
# Always runs on a private, named, throwaway lab session, never the default one
# (tests/herdr-test-safety.sh).
set -u

if [ "${FM_HERDR_AGENT_FREE_PROOF:-0}" != 1 ]; then
  echo "skip: set FM_HERDR_AGENT_FREE_PROOF=1 to run the installed-harness Herdr agent-free proof guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v herdr >/dev/null 2>&1 || fail "herdr not found"
command -v jq >/dev/null 2>&1 || fail "jq not found (required by the herdr adapter)"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

SESSION="fm-lab-agent-free-$$"
export HERDR_SESSION="$SESSION"
LAB=
CLEANED=0
cleanup_all() {
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  [ -n "$LAB" ] && rm -rf "$LAB"
  herdr_safe_stop_and_delete "$SESSION"
}
trap cleanup_all EXIT
fm_herdr_lab_prepare "$SESSION" || fail "could not prepare isolated Herdr lab session"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-herdr-agent-free.XXXXXX")
LAB=$(cd "$LAB" && pwd)
mkdir -p "$LAB/wt"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-cursor-lib.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$LAB/wt") || fail "container_ensure failed"
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED_TAB_ID=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}

HERDR_VERSION=$(herdr --version 2>/dev/null | head -1 | tr -d '\r')
[ -n "$HERDR_VERSION" ] || HERDR_VERSION=unknown
note "herdr: $HERDR_VERSION"

# Mirror bin/fm-spawn.sh's own binary resolution, so this guard covers the same
# binary firstmate would actually launch.
resolve_harness_binary() {  # <harness>
  local harness=$1 candidate
  # cursor first, and never through a bare PATH lookup: it installs as
  # `cursor-agent` plus the legacy alias `agent`, while an unrelated `cursor`
  # on PATH is routinely the editor launcher rather than the agent (observed on
  # a developer machine, where it answered a `--trust` launch with an Electron
  # warning and exited). fm_cursor_resolve_binary is the verified owner
  # fm-spawn itself uses, so this guard launches exactly what firstmate would.
  if [ "$harness" = cursor ]; then
    fm_cursor_resolve_binary 2>/dev/null && return 0
    return 1
  fi
  candidate=$(command -v "$harness" 2>/dev/null || true)
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    printf '%s\n' "$candidate"
    return 0
  fi
  if [ "$harness" = kimi ] && [ -n "${HOME:-}" ] && [ -x "$HOME/.kimi-code/bin/kimi" ]; then
    printf '%s\n' "$HOME/.kimi-code/bin/kimi"
    return 0
  fi
  return 1
}

foreground_names() {  # <pane>
  fm_backend_herdr_cli "$SESSION" pane process-info --pane "$1" 2>/dev/null \
    | jq -r '[.result.process_info.foreground_processes[]? | "\(.name)/\(.argv0 // .argv[0] // "")"] | join(" ")' 2>/dev/null
}

foreground_pids() {  # <pane>
  fm_backend_herdr_cli "$SESSION" pane process-info --pane "$1" 2>/dev/null \
    | jq -r '.result.process_info.foreground_processes[]?.pid | select(type == "number") | floor' 2>/dev/null
}

# end_harness: stop only the exact processes this guard launched into the pane,
# leaving the pane and its tab in place. Closing the pane instead would remove
# the workspace's last tab and destroy the container the next harness needs.
end_harness() {  # <pane>
  local pid
  for pid in $(foreground_pids "$1"); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  for _ in $(seq 1 100); do
    case "$(foreground_names "$1")" in
      ''|*sh/*sh*) return 0 ;;
    esac
    sleep 0.1
  done
  for pid in $(foreground_pids "$1"); do
    kill -KILL "$pid" 2>/dev/null || true
  done
}

CHECKED=0
SKIPPED=

# The verified adapters, in the order .agents/skills/harness-adapters/SKILL.md
# records them. An adapter that gains a verified launch path belongs here too.
for harness in claude codex opencode pi pi-signed grok kimi cursor muse; do
  if ! bin_path=$(resolve_harness_binary "$harness"); then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its Herdr classification is unverified here"
    continue
  fi

  version=$("$bin_path" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version="unknown"

  TASK_IDS=$(fm_backend_herdr_create_task "$CONTAINER" "fm-afp-$harness" "$LAB/wt" "$SEEDED_TAB_ID") \
    || fail "$harness ($version): could not create a lab tab"
  SEEDED_TAB_ID=
  read -r _TAB_ID PANE_ID <<EOF
$TASK_IDS
EOF
  [ -n "$PANE_ID" ] || fail "$harness ($version): create_task returned no pane id"

  # cursor blocks on a workspace-trust prompt in a directory it has never seen,
  # which would hang this probe; --trust is the same flag fm-spawn passes.
  launch=$bin_path
  [ "$harness" = cursor ] && launch="$bin_path --trust"
  fm_backend_herdr_send_text_line "$SESSION:$PANE_ID" "$launch" \
    || fail "$harness ($version): could not launch it in the lab pane"

  # Wait until the harness's OWN executable owns the pane's foreground, so the
  # proof is read against a genuinely running agent rather than the shell that
  # launched it or a short-lived prompt helper beside it.
  bin_base=${bin_path##*/}
  running=0
  for _ in $(seq 1 300); do
    case "$(foreground_names "$PANE_ID")" in
      *"$bin_base"*) running=1; break ;;
    esac
    sleep 0.2
  done
  names=$(foreground_names "$PANE_ID")
  [ "$running" = 1 ] || fail \
    "$harness $version: '$bin_base' never appeared in the Herdr pane's foreground, so this guard proved nothing about it. Observed foreground name/argv0 pairs [$names]. Pane tail: $(fm_backend_herdr_capture "$SESSION:$PANE_ID" 40 2>/dev/null | tail -5 | tr '\n' '|')"

  if fm_backend_herdr_pane_idle_shell_sample "$SESSION" "$PANE_ID" >/dev/null 2>&1; then
    fail "AGENT-FREE DRIFT: $harness $version is running in a Herdr pane, but the pane's process inventory proves a lone bare idle shell, so bin/backends/herdr.sh would classify a live worker as agent-free and let a replacement launch onto its local copy. Observed foreground name/argv0 pairs [$names] on herdr $HERDR_VERSION."
  fi

  # Herdr registers an agent only for the harnesses it ships an integration
  # for, and that integration reports on its own schedule, so give it a bounded
  # window before reading the recovery-grade verdict.
  state=
  for _ in $(seq 1 100); do
    state=$(fm_backend_agent_state herdr "$SESSION:$PANE_ID")
    [ "$state" = alive ] && break
    sleep 0.2
  done
  case "$state" in
    alive) ;;
    dead|missing)
      # No integration ever registered this pane. That is a pre-existing
      # property of the registry, not of the process inventory this guard
      # watches, so it is reported rather than failed.
      note "$harness $version: herdr registered no agent for this harness within the wait (state '$state'); the agent-free proof still correctly refuses"
      ;;
    *) fail "$harness $version: Herdr classified a running harness '$state'; only alive or an unregistered dead/missing is expected" ;;
  esac

  note "$harness $version: foreground=[$names] state=$state"
  pass "herdr agent-free proof: $harness $version running in a Herdr pane never proves a bare idle shell"
  CHECKED=$((CHECKED + 1))

  end_harness "$PANE_ID"
done

[ "$CHECKED" -gt 0 ] || fail \
  "no verified harness is installed here, so this run proved nothing; install at least one harness before trusting a pass"

if [ -n "$SKIPPED" ]; then
  note "unverified on this machine (not installed):$SKIPPED"
fi
note "checked $CHECKED installed harness(es) on herdr $HERDR_VERSION in workspace $WORKSPACE_ID"

cleanup_all
trap - EXIT
