# shellcheck shell=bash
# Source from fm-watch.sh after SCRIPT_DIR resolves the fork's bin directory.
SAMPLER_DIR=${SAMPLER_DIR:-$SCRIPT_DIR}
# shellcheck source=host-memory/bin/fm-host-memory-sampler.sh
. "${BASH_SOURCE[0]%/*}/fm-host-memory-sampler.sh"
