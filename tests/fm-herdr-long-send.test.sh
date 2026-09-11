#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
cat > "$TMP/bin/herdr" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
log=${FM_FAKE_HERDR_LOG:?}
args=("$@")
printf '%s\n' "${args[*]}" >> "$log"
if [ "${args[0]:-}" = status ] && [ "${args[1]:-}" = --json ]; then
  protocol=${FM_FAKE_HERDR_PROTOCOL:-19}
  printf '{"client":{"protocol":%s},"server":{"running":true,"protocol":%s}}\n' "$protocol" "$protocol"
fi
EOF
chmod +x "$TMP/bin/herdr"
export PATH="$TMP/bin:$PATH"
export FM_FAKE_HERDR_LOG="$TMP/herdr.log"

long='[fm-from-firstmate]'$'\u2063''corr=test '
long+=$(printf 'x%.0s' $(seq 1 1000))
long+=TAIL
short='[fm-from-firstmate]'$'\u2063''corr=short SHORT-TAIL'

run() {
  FM_BACKEND_HERDR_SESSION=default FM_BACKEND_HERDR_PANE=w1:p2 \
    bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_send_text_submit "default:w1:p2" "$2" 2 0.01 0.01' _ "$ROOT" "$1"
}

out=$(run "$long")
[ "$out" = empty ] || { echo "long send was not confirmed: $out" >&2; exit 1; }
grep -F 'agent prompt w1:p2' "$FM_FAKE_HERDR_LOG" >/dev/null
grep -F '[fm-from-firstmate]' "$FM_FAKE_HERDR_LOG" >/dev/null
grep -F $'\u2063' "$FM_FAKE_HERDR_LOG" >/dev/null
grep -F 'TAIL' "$FM_FAKE_HERDR_LOG" >/dev/null
! grep -F 'pane send-text' "$FM_FAKE_HERDR_LOG" >/dev/null

: > "$FM_FAKE_HERDR_LOG"
export FM_FAKE_HERDR_PROTOCOL=16
out=$(run "$long")
[ "$out" = send-failed ] || { echo "old Herdr release was not failed closed: $out" >&2; exit 1; }
! grep -F 'pane send-text' "$FM_FAKE_HERDR_LOG" >/dev/null

: > "$FM_FAKE_HERDR_LOG"
short_out=$(FM_BACKEND_HERDR_SESSION=default FM_BACKEND_HERDR_PANE=w1:p2 \
  bash -c '. "$1/bin/backends/herdr.sh";
    fm_backend_herdr_target_ready() { return 0; }
    fm_backend_herdr_send_literal() { printf "pane send-text %s\\n" "$2" >> "$FM_FAKE_HERDR_LOG"; }
    fm_backend_herdr_send_key() { return 0; }
    fm_backend_herdr_agent_status_raw() { printf idle; }
    fm_backend_herdr_wait_for_working() { printf busy; }
    fm_backend_herdr_composer_state() { printf empty; }
    fm_backend_herdr_send_text_submit "default:w1:p2" "$2" 2 0.01 0.01' _ "$ROOT" "$short")
[ "$short_out" = empty ] || { echo "short resend was not confirmed: $short_out" >&2; exit 1; }
grep -F 'SHORT-TAIL' "$FM_FAKE_HERDR_LOG" >/dev/null
grep -F $'\u2063' "$FM_FAKE_HERDR_LOG" >/dev/null

: > "$FM_FAKE_HERDR_LOG"
launch_like=$(printf 'x%.0s' $(seq 1 600))
if FM_BACKEND_HERDR_SESSION=default FM_BACKEND_HERDR_PANE=w1:p2 \
  bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_send_literal "default:w1:p2" "$2"' _ "$ROOT" "$launch_like"; then
  echo "general literal send was not failed closed for a realistic LAUNCH-sized (600 byte) message" >&2
  exit 1
fi
! grep -F 'pane send-text' "$FM_FAKE_HERDR_LOG" >/dev/null

: > "$FM_FAKE_HERDR_LOG"
FM_BACKEND_HERDR_SESSION=default FM_BACKEND_HERDR_PANE=w1:p2 \
  bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_send_literal_command "default:w1:p2" "$2"' _ "$ROOT" "$launch_like"
grep -F 'pane send-text w1:p2' "$FM_FAKE_HERDR_LOG" >/dev/null
grep -F "$launch_like" "$FM_FAKE_HERDR_LOG" >/dev/null

echo 'ok: Herdr long sends use atomic agent prompt without literal PTY insertion'
