#!/usr/bin/env bash
# fm-brain-lib.sh - one owner for resolving this home's brain-axi store, testing
# brain-axi availability, and resolving the attribution tag. Sourced, never
# executed.
#
# brain-axi is an OPTIONAL, one-directional consumer dependency: firstmate calls
# the `brain-axi` binary on PATH, and brain-axi never references firstmate. Every
# caller MUST fail open - brain-axi absent, or its store missing, must never
# break a firstmate flow (session start, remember, brief scaffold). Centralizing
# the questions every caller asks keeps the store path single-owned here.
#
# Usage: . bin/fm-brain-lib.sh
#   store=$(fm_brain_store)          # the home's store path
#   by=$(fm_brain_by <default>)      # attribution tag: $BRAIN_BY wins, else <default>
#   if fm_brain_available; then ...  # binary on PATH AND store dir present

# fm_brain_store: print the home's brain-axi store path.
#   $BRAIN_STORE wins (operator override; also how an isolated home keeps its own
#   store); otherwise the fleet default ~/.brain.
fm_brain_store() {
  if [ -n "${BRAIN_STORE:-}" ]; then
    printf '%s\n' "$BRAIN_STORE"
  else
    printf '%s\n' "${HOME:-}/.brain"
  fi
}

# fm_brain_available: succeed only when the brain-axi binary is on PATH AND the
# resolved store directory already exists. It never creates a store: context_pack
# and delta open the store for WRITE (index migration, delta cursors), so gating
# on an existing directory keeps a read path from materializing an empty store as
# a side effect. remember deliberately does not gate on this - writing is its
# whole purpose - so it checks only the binary.
fm_brain_available() {
  command -v brain-axi >/dev/null 2>&1 || return 1
  local store
  store=$(fm_brain_store)
  [ -n "$store" ] && [ -d "$store" ]
}

# fm_brain_by: print the brain-axi attribution tag. An explicit $BRAIN_BY wins;
# otherwise print the caller-supplied default (which may be empty). Dependency-free
# and never fails: attribution is a pure additive tag, so a missing tag must not
# break the brain-axi call or the lifecycle action around it.
fm_brain_by() {
  printf '%s\n' "${BRAIN_BY:-${1:-}}"
}
