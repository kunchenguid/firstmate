#!/usr/bin/env bash
# Live Kimi-on-Herdr delivery guard (live-harness-optin family).
#
# Kimi Code draws its `Never Ask ... thinking:` status row and its `context:`
# row directly under its bordered composer, and Herdr's native agent_status
# stays idle for a whole Kimi turn, so every Kimi readiness and delivery
# decision on Herdr rests on the shared composer classifier reading those
# vendor-rendered rows (issue 4306). A stub can only confirm the shape already
# written into it, so this guard launches the REAL installed Kimi Code CLI in
# an isolated Herdr lab, in a fresh scratch directory, and requires:
#   - the idle composer to classify empty through fm_backend_herdr_composer_state,
#     the read fm-spawn's readiness gate and delivery confirmation use;
#   - fm_backend_herdr_send_text_submit, the spawn's pointer delivery, to report
#     empty, and Kimi to echo the message and render the requested reply with a
#     nonzero context meter;
#   - after /exit, the pane left at a login shell under Kimi's last composer and
#     footer to classify unknown, never empty.
# It fails naming the Kimi and Herdr versions rather than degrading quietly.
#
# Run explicitly with FM_KIMI_HERDR_DELIVERY_LIVE=1 after a Kimi or Herdr
# upgrade and before trusting refreshed Kimi facts; it submits one short prompt
# to the configured Kimi model. FM_KIMI_LIVE_MODEL passes `--model` (for
# example kimi-code/k3); unset, Kimi uses its configured default model.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
# The scratch directory is new, so Kimi asks to trust it; the guard answers that
# dialog the way fm-spawn does and removes the one trust record Kimi wrote for
# that exact directory on exit.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_KIMI_HERDR_DELIVERY_LIVE herdr jq kimi

[ -x "$LAB_HELPER" ] || fail "FM_KIMI_HERDR_DELIVERY_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
KIMI_HOME_DIR=${KIMI_CODE_HOME:-$HOME/.kimi-code}
SESSION=$("$LAB_HELPER" name kimi-herdr-delivery-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-kimi-herdr-live.XXXXXX")
SCRATCH="$TMP_ROOT/scratch"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$SCRATCH" "$FAKEBIN"
CHECKED=0

# Remove only the trust record Kimi wrote for this guard's scratch directory.
forget_scratch_trust() {
  local record
  for record in "$KIMI_HOME_DIR"/workspace-trust/wd_*; do
    [ -f "$record" ] || continue
    if PATH="$ORIGINAL_PATH" jq -e --arg root "$SCRATCH" '.root == $root' "$record" >/dev/null 2>&1; then
      rm -f "$record"
    fi
  done
}

cleanup() {
  local rc=$?
  trap - EXIT
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  forget_scratch_trust
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
WS_JSON=$(lab workspace create --cwd "$SCRATCH" --label fm-kimilive --no-focus) \
  || fail "could not create the isolated Kimi workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"
VERSION=$(PATH="$ORIGINAL_PATH" kimi --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')
LABEL="Kimi Code $VERSION on $HERDR_VER"

launch='kimi --auto'
[ -z "${FM_KIMI_LIVE_MODEL:-}" ] || launch="kimi --model '$FM_KIMI_LIVE_MODEL' --auto"
lab pane run "$PANE" "$launch" >/dev/null || fail "could not launch $LABEL in the isolated Herdr pane"

# Readiness: answer the fresh directory's trust dialog while it is up, then
# require the shared classifier to read the idle composer empty.
verdict=''
i=0
while [ "$i" -lt 60 ]; do
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  case "$screen" in
    *'Trust this folder?'*'❯ Trust this folder'*)
      lab pane send-keys "$PANE" enter >/dev/null || fail "could not answer Kimi's trust dialog"
      ;;
    *)
      verdict=$(fm_backend_herdr_composer_state "$TARGET")
      [ "$verdict" != empty ] || break
      ;;
  esac
  i=$((i + 1))
  sleep 1
done
CHECKED=1
[ "$verdict" = empty ] \
  || fail "$LABEL: the idle composer never classified empty (last verdict: ${verdict:-none}); readiness and delivery confirmation cannot pass"
pass "$LABEL: the idle composer under Kimi's status and context rows classifies empty"

TOKEN="FMKIMIPONG$$${RANDOM}"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "Reply with exactly $TOKEN and nothing else." 3 0.5 0) \
  || fail "send_text_submit failed to run against $LABEL"
[ "$verdict" = empty ] \
  || fail "$LABEL: delivery through the spawn's submit path must confirm empty, got '$verdict'"
landed=0
i=0
while [ "$i" -lt 90 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  if [ "$(printf '%s\n' "$screen" | grep -F -c "$TOKEN" || true)" -ge 2 ] \
     && printf '%s\n' "$screen" | grep -F '✨' | grep -Fq "$TOKEN" \
     && printf '%s\n' "$screen" | grep -Eq 'context:[[:space:]]*[1-9][0-9]*%|context:[[:space:]]*0\.[0-9]*[1-9]'; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] \
  || fail "$LABEL: submit reported '$verdict' but the echoed message, reply, and nonzero context never rendered"
pass "$LABEL: the submit path delivers a prompt that Kimi echoes and answers"

verdict=$(fm_backend_herdr_send_text_submit "$TARGET" '/exit' 3 0.5 0) \
  || fail "send_text_submit failed to run the /exit submission against $LABEL"
exited=0
i=0
while [ "$i" -lt 30 ]; do
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  case "$screen" in *'Bye!'*) exited=1; break ;; esac
  i=$((i + 1))
  sleep 1
done
[ "$exited" = 1 ] || fail "$LABEL: /exit reported '$verdict' but Kimi never printed its exit line"
sleep 1
verdict=$(fm_backend_herdr_composer_state "$TARGET")
[ "$verdict" = unknown ] \
  || fail "$LABEL: a pane left at a login shell under Kimi's last composer must classify unknown, got '$verdict'"
pass "$LABEL: after /exit the leftover composer and footer above a shell classify unknown"

[ "$CHECKED" -gt 0 ] || fail "FM_KIMI_HERDR_DELIVERY_LIVE=1 checked no harness"
