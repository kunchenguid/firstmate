#!/usr/bin/env bash
# Read-only detection sweep for modern Pi author-identity metadata gaps.
# Usage: fm-author-identity-sweep.sh
# Prints one diagnostic line per ship/scout whose metadata records the immutable
# launch-bound-v1 epoch without exactly one non-empty author_account_identity:
#   AUTHOR_IDENTITY_CAPTURE_GAP: <id>: modern Pi task metadata ...
# This gap is informational: structural reviewer independence means it must not
# block spawn, review, or merge. Silence means no matching record was found.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

[ -d "$STATE" ] && [ ! -L "$STATE" ] || exit 0

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] && [ ! -L "$meta" ] || continue
  if awk '
    BEGIN { kind = "ship" }
    index($0, "harness=") == 1 {
      harness_count++
      harness = substr($0, 9)
    }
    index($0, "kind=") == 1 {
      kind_count++
      kind = substr($0, 6)
    }
    index($0, "author_identity_snapshot_epoch=") == 1 {
      epoch_count++
      epoch = substr($0, 32)
    }
    index($0, "author_account_identity=") == 1 {
      identity_count++
      identity = substr($0, 25)
    }
    END {
      relevant_kind = kind_count <= 1 && (kind == "ship" || kind == "scout")
      modern_pi = harness_count == 1 && harness == "pi" \
        && epoch_count == 1 && epoch == "launch-bound-v1"
      admissible_identity = identity_count == 1 && identity != ""
      exit(relevant_kind && modern_pi && !admissible_identity ? 0 : 1)
    }
  ' "$meta"; then
    id=${meta##*/}
    id=${id%.meta}
    printf 'AUTHOR_IDENTITY_CAPTURE_GAP: %s: modern Pi task metadata records launch-bound-v1 without exactly one non-empty author_account_identity; informational only, review independence is structural\n' "$id"
  fi
done
