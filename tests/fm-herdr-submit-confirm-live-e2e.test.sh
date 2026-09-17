#!/usr/bin/env bash
# Live Herdr submit-confirmation guard (live-harness-optin family).
#
# Herdr's native agent_status can stay idle for a whole landed Claude turn, and
# a busy-queued Enter can keep proven pending text visible. Muse can also leave
# the native probe unreadable while a bare U+27E9 composer proves its message
# landed. A stub cannot prove any of those signals. This guard launches real
# Claude Code, and an installed Muse Code on its echo provider, in an isolated
# Herdr lab, requiring fm_backend_herdr_send_text_submit to report empty for
# each landed steer. It fails naming the harness and version rather than
# degrading quietly.
#
# Run explicitly with FM_HERDR_SUBMIT_CONFIRM_LIVE=1 after a Herdr, Claude, or
# Muse upgrade, and before trusting a refreshed
# docs/verification/runtime-backends.md "Herdr submit confirmation" entry.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

# Same quoting bin/fm-spawn.sh applies to the values it substitutes into a
# launch command, so a path holding spaces or quotes survives the pane shell.
shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

fm_live_gate opt-in FM_HERDR_SUBMIT_CONFIRM_LIVE herdr jq claude

[ -x "$LAB_HELPER" ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name herdr-submit-confirm-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-submit-confirm-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
CHECKED=0

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-submitlive --no-focus) \
  || fail "could not create the isolated submit-confirm workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

lab pane run "$PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null \
  || fail "could not launch Claude Code ($VERSION) in the isolated Herdr pane"

idle=0
i=0
while [ "$i" -lt 45 ]; do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in idle|done|blocked) idle=1; break ;; esac
  i=$((i + 1))
  sleep 1
done
[ "$idle" = 1 ] || fail "Claude Code ($VERSION) on $HERDR_VER never registered an idle agent in the lab pane"

TOKEN="FMHERDRPONG$$_$RANDOM"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "Reply with exactly $TOKEN and nothing else." 3 0.4 0.4) \
  || fail "send_text_submit failed to run against Claude Code ($VERSION) on $HERDR_VER"
CHECKED=1
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a landed idle steer must confirm empty, got '$verdict'"

# Confirm the instruction reached Claude, not merely that the composer cleared.
# The token occurs once in the submitted prompt and once in Claude's reply.
landed=0
i=0
screen=''
while [ "$i" -lt 45 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  occurrences=$(printf '%s\n' "$screen" | grep -F -c "$TOKEN" || true)
  if [ "$occurrences" -ge 2 ]; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: submit reported '$verdict' but the expected reply never rendered"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER reports empty and renders the requested reply in isolated session $SESSION"

# Muse normally has no registered Herdr agent state, so this probes the exact
# fallback path that once reported a false unconfirmed send despite a visible
# Muse turn. The installed-harness rule is deliberate: an absent Muse is
# reported rather than fabricated as a pass, while an installed Muse must prove
# its current renderer and send behavior before it can be trusted.
# The leg drives a real Muse with --provider echo under an isolated XDG lab,
# the same credential-free shape tests/fm-muse-signals-live-e2e.test.sh already
# proves a real Muse with, so it is runnable wherever muse is installed and
# never points a sandbox-disabled --yolo Muse at the operator's real config
# home, data home, or repository.
# The tradeoff is stated plainly rather than hidden: an echo reply is a runtime
# echo and not a model answer, so what this asserts is delivery to the Muse
# runtime, which is exactly the delivery mechanic this repair exists to prove.
# Exercising the credentialed provider belongs to real Muse work routing and to
# docs/verification/muse.md, not to this guard, so the echo provider is a
# deliberate scope boundary here rather than a gap.
MUSE_BIN=$(PATH="$ORIGINAL_PATH" command -v muse 2>/dev/null || true)
if [ -z "$MUSE_BIN" ]; then
  printf '# muse is not installed; Muse-on-Herdr submit confirmation was not verified here\n'
else
  # muse has no probe-friendly version flag, and the build this record must name
  # is the one actually running in the pane, so the version is read below from
  # the pane's own process info once the readiness gate has seen it. Until then
  # the messages carry the honest placeholder.
  MUSE_VERSION=version-unknown
  MUSE_CONFIG_HOME="$TMP_ROOT/muse-config"
  MUSE_DATA_HOME="$TMP_ROOT/muse-data"
  MUSE_WORKSPACE="$TMP_ROOT/muse-workspace"
  mkdir -p "$MUSE_CONFIG_HOME" "$MUSE_DATA_HOME" "$MUSE_WORKSPACE" \
    || fail "could not create the isolated Muse lab under $TMP_ROOT"
  git -C "$MUSE_WORKSPACE" init -q \
    || fail "could not initialize the isolated Muse workspace at $MUSE_WORKSPACE"
  MUSE_TAB_JSON=$(lab tab create --workspace "$(printf '%s' "$WS_JSON" | jq -er '.result.workspace.workspace_id')" --cwd "$MUSE_WORKSPACE" --label fm-submitlive-muse --no-focus) \
    || fail "could not create a Muse tab in the isolated Herdr workspace"
  MUSE_PANE=$(printf '%s' "$MUSE_TAB_JSON" | jq -er '.result.root_pane.pane_id') \
    || fail "Muse tab create did not return a pane id"
  MUSE_TARGET="$SESSION:$MUSE_PANE"
  # The launch shape here is the launch bin/fm-spawn.sh actually composes for
  # muse minus its positional brief, since this guard needs an idle composer to
  # steer: the shared outer marker scrub bin/fm-spawn.sh prefixes onto every
  # marker-bearing harness (the `env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u
  # GEMINI_CLI` wrap in its `case "$HARNESS" in` LAUNCH prefix) around the
  # verified `muse)` arm of that file's launch-template case, the same absolute
  # resolved binary, and MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on as the
  # privacy control, which is the control used because the interactive TUI
  # rejects exec mode's --no-foreign-personal-context flag.
  # Two deviations are deliberate: the XDG homes point at this guard's isolated
  # lab rather than the operator's, and --provider echo replaces the
  # credentialed provider so the leg needs no credential.
  MUSE_LAUNCH=$(printf 'env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on %s --provider echo --yolo' \
    "$(shell_quote "$MUSE_CONFIG_HOME")" "$(shell_quote "$MUSE_DATA_HOME")" "$(shell_quote "$MUSE_BIN")")
  lab pane run "$MUSE_PANE" "$MUSE_LAUNCH" >/dev/null \
    || fail "could not launch Muse Code ($MUSE_VERSION) in the isolated Herdr pane"

  # muse_pane_exec_name: the pane's live muse-bin-<version> identity, empty when
  # the pane is not running one. muse's launcher execs a version-suffixed
  # muse-bin-<version>, which docs/verification/muse.md treats as muse's
  # authoritative version surface.
  # Only the argv surfaces are read, never the kernel process name: that name is
  # truncated (15 bytes on Linux, 16 on macOS), and a real muse identity
  # truncates mid-version to a build that never existed while still carrying the
  # muse-bin- prefix, so admitting it would put a fabricated version into the
  # pass line and into the verification record. An unreadable argv leaves the
  # honest version-unknown placeholder instead.
  # The suffix is shape-checked for the same reason: only a non-empty version
  # after the prefix may name a build.
  muse_pane_exec_name() {
    lab pane process-info --pane "$1" 2>/dev/null | jq -r '
      [.result.process_info.foreground_processes[]?
       | ((.argv // [])[0] // empty), (.argv0 // empty)]
      | map(split("/") | last)
      | map(select(test("^muse-bin-.+$")))
      | first // empty' 2>/dev/null || true
  }

  # An empty composer alone is not proof Muse is up: the shared classifier reads
  # a bare shell prompt row as empty too, so a pane that never became Muse would
  # be steered into its own shell. Nor is the shared process probe enough on its
  # own: `command -v muse` is the launcher, whose bare `muse` argv[0] the shared
  # classifier already owns as an agent name, so the launcher window satisfies
  # the process signal and a not-yet-painted row satisfies the composer signal on
  # the very same tick. The exec'd muse-bin-<version> identity is what separates
  # the launcher from the TUI it becomes, so readiness demands all three.
  muse_idle=0
  i=0
  muse_state=unread
  muse_process=unread
  muse_exec_name=
  while [ "$i" -lt 90 ]; do
    muse_process=$(fm_backend_herdr_pane_process_state "$SESSION" "$MUSE_PANE")
    if [ "$muse_process" = agent ]; then
      muse_exec_name=$(muse_pane_exec_name "$MUSE_PANE")
      if [ -n "$muse_exec_name" ]; then
        muse_state=$(fm_backend_herdr_composer_state "$MUSE_TARGET")
        [ "$muse_state" = empty ] && { muse_idle=1; break; }
      fi
    fi
    i=$((i + 1))
    sleep 1
  done
  [ "$muse_idle" = 1 ] \
    || fail "Muse Code ($MUSE_VERSION) on $HERDR_VER never reached a live muse-bin process with a shared empty composer in the lab pane (last process state '$muse_process', last exec identity '${muse_exec_name:-none}', last composer state '$muse_state')"

  # The build that ran is the build this record may name, and the gate above
  # already read it off the pane before opening.
  MUSE_VERSION=${muse_exec_name#muse-bin-}

  # Best-effort route preference, not proof: a readable native status here means
  # fm_backend_herdr_send_text_submit would take its native branch instead of
  # the composer one this leg is about, so a verdict from this run could not be
  # attributed to either. It proves nothing on its own, because
  # fm_backend_herdr_agent_status_raw returns the same empty string for a pane
  # with no registered agent and for an agent get that simply failed.
  # A Herdr that starts registering an agent for Muse panes is an upstream
  # improvement rather than a firstmate defect, so this reports unverified and
  # skips the leg exactly as an absent Muse does, leaving CHECKED untouched
  # instead of turning an unchanged repository red.
  muse_raw=$(fm_backend_herdr_agent_status_raw "$SESSION" "$MUSE_PANE")
  if [ -n "$muse_raw" ]; then
    printf '# herdr now registers a native agent for the Muse pane (agent_status %s), so a steer would take the native branch rather than the composer fallback this leg covers; Muse-on-Herdr submit confirmation was not verified here\n' \
      "$muse_raw"
  else
    MUSE_TOKEN="FMHERDRMUSE$$_$RANDOM"
    muse_verdict=$(fm_backend_herdr_send_text_submit "$MUSE_TARGET" "Reply with exactly $MUSE_TOKEN and nothing else." 3 0.4 0.4) \
      || fail "send_text_submit failed to run against Muse Code ($MUSE_VERSION) on $HERDR_VER"
    CHECKED=$((CHECKED + 1))
    [ "$muse_verdict" = empty ] \
      || fail "Muse Code ($MUSE_VERSION) on $HERDR_VER: a landed steer must confirm empty, got '$muse_verdict'"

    # Same two-occurrence rule as the Claude leg: the token must appear in the
    # submitted prompt and again in the echo provider's reply, so a merely
    # cleared composer cannot pass for a delivered instruction.
    muse_landed=0
    i=0
    while [ "$i" -lt 90 ]; do
      muse_screen=$(lab pane read "$MUSE_PANE" --source recent --lines 200 2>/dev/null || true)
      muse_occurrences=$(printf '%s\n' "$muse_screen" | grep -F -c "$MUSE_TOKEN" || true)
      if [ "$muse_occurrences" -ge 2 ]; then
        muse_landed=1
        break
      fi
      i=$((i + 1))
      sleep 1
    done
    [ "$muse_landed" = 1 ] \
      || fail "Muse Code ($MUSE_VERSION) on $HERDR_VER: submit reported '$muse_verdict' but the expected reply never rendered"
    pass "live Herdr submit confirm: Muse Code ($MUSE_VERSION) on $HERDR_VER: the shared classifier read its idle bare U+27E9 row as empty, the steer confirmed empty, and the echo provider rendered the requested reply in isolated session $SESSION"
  fi
fi

[ "$CHECKED" -gt 0 ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 checked no harness"
