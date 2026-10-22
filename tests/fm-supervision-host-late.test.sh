#!/usr/bin/env bash
# Second group of the supervision-host behavior suite; run on a separate serial CI shard.
FM_SUPERVISION_HOST_TEST_GROUP=late
# shellcheck source=tests/fm-supervision-host.test.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-supervision-host.test.sh"
