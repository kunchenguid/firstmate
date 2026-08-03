#!/usr/bin/env bash
# tests/fm-harness-liveness-drift-live-e2e.test.sh - opt-in drift guard proving
# every INSTALLED harness is still classified `alive` by the tmux liveness
# probe (bin/backends/tmux.sh).
#
# Why this file exists: liveness classification depends on how a harness names
# its own process, which is a surface the harness vendor controls and changes
# without notice. Claude Code began reporting its version string as its process
# name and became unattributable, which silently degraded supervision. A
# regression that only a real harness release can cause needs a check that runs
# real harnesses; a stubbed agent cannot see it, and neither can a table of
# names transcribed from a previous release.
#
# Each harness is launched bare, with no prompt, so this consumes no model
# tokens. The launch uses whatever credentials the harness already has; an
# unauthenticated harness still starts its process, which is all the liveness
# probe reads.
#
# The portable, harness-free counterpart is tests/fm-tmux-agent-liveness.test.sh,
# which pins the classifier's logic everywhere CI runs tmux.
set -u

if [ "${FM_HARNESS_LIVENESS_DRIFT:-0}" != 1 ]; then
  echo "skip: set FM_HARNESS_LIVENESS_DRIFT=1 to run the installed-harness liveness drift guard"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }
note() { printf '# %s\n' "$1"; }

command -v tmux >/dev/null 2>&1 || fail "tmux not found"
REAL_TMUX=$(command -v tmux)
SOCKET="fm-liveness-drift-$$"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-liveness-drift.XXXXXX")
SESSION=drift

cleanup_all() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  [ -n "${LAB:-}" ] && rm -rf "$LAB"
}
trap cleanup_all EXIT

mkdir -p "$LAB/shim" "$LAB/wt"
cat > "$LAB/shim/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/shim/tmux"
PATH="$LAB/shim:$PATH"
export PATH

# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "fm_backend_source tmux failed"

"$REAL_TMUX" -L "$SOCKET" new-session -d -s "$SESSION" -n control -c "$LAB/wt" \
  || fail "could not start the private tmux server"

# Kimi is not required to be on PATH; mirror bin/fm-spawn.sh's own resolution
# order so this guard covers the same binary firstmate would actually launch.
resolve_harness_binary() {  # <harness>
  local harness=$1 candidate
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

# Does the title-INDEPENDENT source, on its own, attribute this pane to a
# verified harness? This is the assertion that actually catches drift: the
# classifier could still return `alive` from the rewritable process title alone,
# which is exactly the signal a harness release is free to break.
comms_attribute_agent() {  # <target>
  local name
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$(fm_backend_tmux_classify_process_name "$name")" = agent ] && return 0
  done <<EOF
$(fm_backend_tmux_foreground_comms "$1")
EOF
  return 1
}

CHECKED=0
SKIPPED=

# The verified adapters, in the order .agents/skills/harness-adapters/SKILL.md
# records them. An adapter that gains a verified launch path belongs here too.
for harness in claude codex opencode pi pi-signed grok kimi; do
  if ! bin_path=$(resolve_harness_binary "$harness"); then
    SKIPPED="$SKIPPED $harness"
    note "skip: $harness is not installed on this machine, so its classification is unverified here"
    continue
  fi

  version=$("$bin_path" --version 2>/dev/null | head -1 | tr -d '\r') || version=
  [ -n "$version" ] || version="unknown"

  target="$SESSION:$harness"
  "$REAL_TMUX" -L "$SOCKET" new-window -d -t "$SESSION:" -n "$harness" -c "$LAB/wt" -- "$bin_path" \
    || fail "$harness ($version): could not launch a window for the liveness probe"

  state=
  for _ in $(seq 1 300); do
    state=$(fm_backend_agent_state tmux "$target")
    [ "$state" = alive ] && break
    sleep 0.2
  done

  title=$(fm_backend_tmux_current_command "$target")
  comms=$(fm_backend_tmux_foreground_comms "$target" | tr '\n' ' ')

  [ "$state" = alive ] || fail \
    "LIVENESS DRIFT: $harness $version is running but classifies '$state', not 'alive'. Supervision and lifecycle control treat this endpoint as unattributable. Observed process title '$title'; observed foreground process names [$comms]. Teach bin/backends/tmux.sh's fm_backend_tmux_classify_process_name the identity this release actually reports."

  comms_attribute_agent "$target" || fail \
    "LIVENESS DRIFT: $harness $version classifies alive only from its rewritable process title '$title'; the kernel foreground process names [$comms] no longer attribute it. The verdict now rests on a single surface the vendor can change without notice."

  # An informational record of which source carried the verdict. Deliberately
  # not asserted: which one wins is a per-release, per-platform detail, and
  # pinning it here would turn a healthy harness update into a failing test.
  title_name=${title##*/}
  title_name=${title_name#-}
  if [ "$(fm_backend_tmux_classify_process_name "$title_name")" = agent ]; then
    carried="both sources"
  else
    carried="the kernel foreground names only (its process title does not attribute it)"
  fi
  note "$harness $version: title='$title' foreground=[$comms] attributed by $carried"

  pass "harness liveness: $harness $version classifies alive, attributed by a name source independent of its process title"
  CHECKED=$((CHECKED + 1))
done

[ "$CHECKED" -gt 0 ] || fail \
  "no verified harness is installed here, so this run proved nothing; install at least one harness before trusting a pass"

if [ -n "$SKIPPED" ]; then
  note "unverified on this machine (not installed):$SKIPPED"
fi
note "checked $CHECKED installed harness(es)"

cleanup_all
trap - EXIT
