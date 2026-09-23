# shellcheck shell=bash
# Shared typed-dispatch confidence boundary.
# Usage: . bin/fm-dispatch-lib.sh
#
# FM_DISPATCH_CONFIDENCE_FLOOR is the global minimum rule-match confidence
# bin/fm-dispatch-resolve.sh requires before it emits a profile, and the same
# number is the boundary below which a declared confidence floor requires the
# matching strongest-reasoning declaration.
#
# This file is the single owner of that number. bin/fm-dispatch-resolve.sh
# applies it and bin/fm-bootstrap.sh reports the same boundary in its
# CREW_DISPATCH diagnostic, so the validator that must catch a bad floor and
# the resolver that enforces it can never disagree about where the floor is.

# shellcheck disable=SC2034 # Shared floor consumed by the sourcing callers named above.
FM_DISPATCH_CONFIDENCE_FLOOR=0.6
