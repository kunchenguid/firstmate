#!/usr/bin/env bash
# Launch a Codex primary with generic agent-turn-complete notifications disabled.
#
# Run with --help for usage and the launch rationale.
#
# Codex intentionally refuses project-local `notify` configuration because it
# runs a machine-local command. A CLI override is the supported higher-precedence
# seam that leaves the captain's global Codex notification settings untouched.
# Firstmate's project hooks then own the narrower captain-wait sound through
# bin/fm-captain-wait.sh.
set -u

case ${1:-} in
  -h|--help)
    cat <<'EOF'
Usage: fm-codex-primary.sh [codex arguments...]

Launch Codex with its machine-global generic turn-complete `notify` callback replaced by
a silent command. Firstmate's tracked hooks and fm-captain-wait.sh then own the
narrow captain-response notification lifecycle. All other arguments pass to Codex.
EOF
    exit 0
    ;;
esac

exec codex -c 'notify=["true"]' "$@"
