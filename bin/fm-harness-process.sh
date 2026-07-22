#!/usr/bin/env bash
# Identify a verified harness process without matching unrelated argv values.
# Usage: fm-harness-process.sh <pid>
# Prints claude|codex|opencode|pi|grok and exits 0 when the PID is a supported
# native executable or an interpreter-hosted package entrypoint; exits 1 otherwise.
set -u

pid=${1:-}
case "$pid" in ''|*[!0-9]*|1) exit 1 ;; esac
[ -r "/proc/$pid/cmdline" ] || exit 1

executable=$(python3 - "$pid" 2>/dev/null <<'PY'
import os, sys
print(os.readlink(f"/proc/{sys.argv[1]}/exe"))
PY
) || exit 1
case "$executable" in
  */claude) printf '%s\n' claude; exit 0 ;;
  */codex) printf '%s\n' codex; exit 0 ;;
  */opencode) printf '%s\n' opencode; exit 0 ;;
  */pi) printf '%s\n' pi; exit 0 ;;
  */grok) printf '%s\n' grok; exit 0 ;;
esac

name=$(basename "$executable")
mapfile -d '' -t argv < "/proc/$pid/cmdline" 2>/dev/null || exit 1
case "$name" in
  node|nodejs)
    entrypoint=${argv[1]:-}
    ;;
  *)
    exit 1
    ;;
esac
[ -n "$entrypoint" ] || exit 1
case "$entrypoint" in
  /*) entrypoint=$(readlink -f "$entrypoint" 2>/dev/null) || exit 1 ;;
  *) entrypoint=$(readlink -f "/proc/$pid/cwd/$entrypoint" 2>/dev/null) || exit 1 ;;
esac

entrypoint=$(printf '%s' "$entrypoint" | tr '[:upper:]' '[:lower:]')
case "$entrypoint" in
  */node_modules/@anthropic-ai/claude-code/cli.js|\
  */node_modules/@anthropic-ai/claude-code/bin/claude.js)
    printf '%s\n' claude
    ;;
  */node_modules/@openai/codex/bin/codex.js)
    printf '%s\n' codex
    ;;
  */node_modules/@mariozechner/pi-coding-agent/dist/cli.js|\
  */node_modules/@earendil-works/pi-coding-agent/dist/cli.js)
    printf '%s\n' pi
    ;;
  */node_modules/opencode-ai/bin/opencode.js)
    printf '%s\n' opencode
    ;;
  *)
    exit 1
    ;;
esac
