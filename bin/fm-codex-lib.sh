#!/usr/bin/env bash
# Shared Codex capability probes.
set -u

FM_CODEX_MAX_EFFORT_MIN=0.151.0

fm_codex_supports_max_effort() {  # <executable>
  tool_version_at_least "$1" "$FM_CODEX_MAX_EFFORT_MIN"
}
