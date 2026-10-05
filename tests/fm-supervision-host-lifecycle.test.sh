#!/usr/bin/env bash
# The second half of tests/fm-supervision-host.test.sh, split off so neither
# half alone outgrows a portable serial CI shard: the engine-error latch, the
# bounded and reaped engine turn, the park boundary and its limits, and host
# ownership. The fixture, stub engine, and cases all live in that file.
FM_SUPERVISION_HOST_HALF=lifecycle
# shellcheck source=tests/fm-supervision-host.test.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-supervision-host.test.sh"
