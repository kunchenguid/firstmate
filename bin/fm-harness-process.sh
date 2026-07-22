#!/usr/bin/env bash
# Identify a verified harness process without matching unrelated argv values.
# Usage: fm-harness-process.sh <pid>
# Prints claude|codex|opencode|pi|grok and exits 0 when the PID is a supported
# native executable or an interpreter-hosted package entrypoint; exits 1 otherwise.
set -u

pid=${1:-}
case "$pid" in ''|*[!0-9]*|1) exit 1 ;; esac
[ -r "/proc/$pid/cmdline" ] || exit 1

supported_harness() {
  case "$1" in codex|pi|grok|claude|opencode) printf '%s\n' "$1"; return 0 ;; esac
  return 1
}

mapfile -d '' -t argv < "/proc/$pid/cmdline" 2>/dev/null || exit 1
comm=$(ps -o comm= -p "$pid" 2>/dev/null || true)
for executable in "${argv[0]:-}" "$comm"; do
  name=$(basename "$executable")
  supported_harness "$name" && exit 0
done

case "$(basename "${argv[0]:-}")" in
  node|nodejs|python|python[0-9]|python[0-9].*) entrypoint=${argv[1]:-} ;;
  *) exit 1 ;;
esac
[ -n "$entrypoint" ] || exit 1
case "$entrypoint" in
  /*) ;;
  *) entrypoint="$(readlink -f "/proc/$pid/cwd/$entrypoint" 2>/dev/null || printf '%s' "$entrypoint")" ;;
esac

while IFS= read -r component; do
  normalized=$(printf '%s' "$component" | tr '[:upper:]' '[:lower:]')
  for harness in opencode claude codex grok pi; do
    case "$normalized" in
      "$harness"|"$harness"[-_.]*|*[-_.]"$harness"|*[-_.]"$harness"[-_.]*) printf '%s\n' "$harness"; exit 0 ;;
    esac
  done
done < <(printf '%s\n' "$entrypoint" | tr '/' '\n')
exit 1
