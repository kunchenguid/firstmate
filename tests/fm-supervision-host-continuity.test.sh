#!/usr/bin/env bash
# The later host-cycle cases share the fixture and assertions with the first
# part, but occupy their own serial CI shard for a bounded job duration.
FM_SUPERVISION_HOST_TEST_PART=2
# shellcheck source=tests/fm-supervision-host.test.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-supervision-host.test.sh"
