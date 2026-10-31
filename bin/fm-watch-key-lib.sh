#!/usr/bin/env bash
# Shared watcher marker identity. Source this library, then call window_key
# with one backend endpoint to obtain its filename suffix.
#
# Every per-window watcher marker consumes this ONE derivation. SHA-256 of the
# endpoint bytes with a `v3.` prefix bounds the suffix to 67 ASCII bytes, leaving
# room for marker prefixes within a 255-byte filename. The dot cannot occur in a
# legacy key; legacy and v2 evidence is ignored, never migrated or revived.
# Identity depends only on endpoint bytes, never on other recorded windows.
# docs/configuration.md's watcher-marker upgrade note owns the intentional
# one-time cache reset and its notification-only effects.
#
# Obsolete markers are not garbage-collected automatically. For optional cleanup,
# stop both the watcher and away daemon, then archive the obsolete files outside
# STATE (or remove the reviewed files). Limit this to per-endpoint marker families:
# .hash-, .count-, .stale-, .stale-since-, .churn-since-, .dead-reported-,
# .wedge-escalations-, .wedge-permanent-, .wedge-terminal-queued-,
# .wedge-rollback-failed-, .paused-, .paused-rechecked-, .paused-resurfaced-,
# .waiting-resurfaced-, .writing-since-, .writing-resurfaced-, .validating-since-,
# .validating-resurfaced-, and .guard-deferrals-. Preserve every current filename
# containing -v3.; only legacy/v2 suffixes in those families are obsolete.
# Do not bulk-clear STATE: task records, wake queues, and task-keyed .subsuper-*
# markers are outside this cleanup. Leaving obsolete files in place is safe.
window_key() {  # <window>
  local digest
  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s' "$1" | shasum -a 256)
  else
    digest=$(printf '%s' "$1" | sha256sum)
  fi
  printf 'v3.%s' "${digest%% *}"
}
