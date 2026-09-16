#!/usr/bin/env bash
# Existing-home migration through the shared real remote lifecycle fixture:
# bin/fm-remote-home-migrate.sh and bin/fm-home-migration-lib.sh, reached the way
# operators reach them, through bin/fm-remote-home-seed.sh --migrate.
# No real SSH host or Herdr session is contacted.
set -eu
FM_TEST_MIGRATION_ONLY=1 exec bash "$(dirname "${BASH_SOURCE[0]}")/fm-remote-secondmate-lifecycle-e2e.test.sh"
