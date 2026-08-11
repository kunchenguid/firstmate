#!/usr/bin/env bash
# fm-accounts-prereq.sh — ensure the LLM CLIs multi-account needs are installed
# (Phase 4 add-on). USER-SCOPED, no sudo. Detect by default; install on request.
#
#   fm-accounts-prereq.sh                       # detect: installed / MISSING + install cmd
#   fm-accounts-prereq.sh install               # install every MISSING harness
#   fm-accounts-prereq.sh install cursor-agent  # install specific harness(es)
#   fm-accounts-prereq.sh install --yes cursor-agent   # skip the curl|sh prompt (reviewed)
#
# pi is system-managed (/usr/bin) -> DETECT ONLY, never installed here.
# Install commands are user-scoped (npm prefix must be a user dir; cursor's
# installer writes to ~/.local). Review any remote-script install before running.
set -euo pipefail

# harness -> install command (verified 2026-07-26). nonzero => not installable here.
fm_prereq_cmd() { # harness
  case "$1" in
    claude)       echo 'npm install -g @anthropic-ai/claude-code' ;;
    codex)        echo 'npm install -g @openai/codex' ;;
    grok)         echo 'npm install -g @vibe-kit/grok-cli' ;;
    cline)        echo 'npm install -g cline' ;;
    cursor-agent) echo 'curl https://cursor.com/install -fsS | bash' ;;
    pi)           return 1 ;;   # system-managed; install via Pi, not here
    *) return 1 ;;
  esac
}

HARNESSES="claude codex pi grok cline cursor-agent"

detect() {
  printf '%-14s %-10s %s\n' HARNESS STATUS DETAIL
  local h
  for h in $HARNESSES; do
    if command -v "$h" >/dev/null 2>&1; then
      printf '%-14s %-10s %s\n' "$h" "installed" "$(command -v "$h") ($("$h" --version 2>/dev/null | head -n1))"
    elif [ "$h" = pi ]; then
      printf '%-14s %-10s %s\n' "$h" "MISSING" "system-managed (install via Pi; not handled here)"
    else
      printf '%-14s %-10s %s\n' "$h" "MISSING" "install: $(fm_prereq_cmd "$h")"
    fi
  done
}

# True when the command pipes into a shell ANYWHERE, not just at its very end:
# `| bash -s -- --prefix ~/.local` and `| sh -` are the same "pipe a remote script
# into a shell" shape as a bare `| bash`, and all of them reach the eval below.
# Matching only the suffix would let a future entry skip the review prompt.
fm_prereq_pipes_to_shell() { # cmd
  [[ $1 =~ \|[[:space:]]*(env[[:space:]]+)?([^[:space:]]*/)?(ba|da|k|z|a)?sh([[:space:]]|$) ]]
}

install_one() { # harness yes
  local h=$1 yes=$2 cmd ans
  if command -v "$h" >/dev/null 2>&1; then echo "[skip] $h already installed"; return 0; fi
  if [ "$h" = pi ]; then echo "[skip] pi is system-managed; install it via Pi, not here"; return 0; fi
  cmd=$(fm_prereq_cmd "$h") || { echo "[err] no install command for '$h'" >&2; return 1; }
  if [ "$yes" != 1 ] && fm_prereq_pipes_to_shell "$cmd"; then
    echo "[review] $h installs via a remote script:"; echo "    $cmd"
    printf "  run it? [y/N] "; read -r ans || ans=n
    [ "$ans" = y ] || [ "$ans" = Y ] || { echo "[skip] $h (declined)"; return 0; }
  fi
  echo "[install] $h: $cmd"; eval "$cmd"
}

case "${1:-detect}" in
  detect|"") detect ;;
  install)
    shift; yes=0; targets=()
    for a in "$@"; do case "$a" in --yes|-y) yes=1 ;; *) targets+=("$a") ;; esac; done
    if [ "${#targets[@]}" -eq 0 ]; then
      for h in $HARNESSES; do command -v "$h" >/dev/null 2>&1 || targets+=("$h"); done
    fi
    if [ "${#targets[@]}" -eq 0 ]; then echo "all harnesses present; nothing to install"; exit 0; fi
    for h in "${targets[@]}"; do install_one "$h" "$yes"; done ;;
  *) echo "usage: fm-accounts-prereq.sh [detect|install [--yes] [harness...]]" >&2; exit 1 ;;
esac
