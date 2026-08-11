#!/usr/bin/env bash
# fm-ci-codebase-lane.sh - run one behavior lane inside the Codebase CI image.
#
# Only .codebase/pipelines/ci.yaml calls this, once per sharded job, after
# bin/fm-ci-codebase-setup.sh has provisioned the image.
#
# Composition owner is bin/fm-test-run.sh (docs/fm-test-portable-shards.md);
# this script owns nothing about WHICH tests run, only the two environment
# requirements the runner needs on this image, both learned the hard way:
#
# 1. NOT as root. tests/fm-daemon.test.sh chmods a state dir unwritable and
#    asserts the write fails; root ignores permission bits, so as root that
#    assertion silently inverts. GitHub's runner is non-root; this image is
#    root, so the suite is re-run through an unprivileged user.
#
# 2. A hermetic git config. The runner ships a global url.<...>.insteadOf
#    rewrite for code.byted.org, and `git remote get-url` APPLIES insteadOf -
#    so tests/fm-teardown.test.sh's Codebase fixture reads back as
#    gitlab@git.byted.org, the provider parser stops recognizing it as
#    Codebase, and teardown refuses work the test says is landed.
#    GIT_CONFIG_GLOBAL/SYSTEM=/dev/null drops that rewrite (and any other
#    runner-local git surprise); the GIT_* identity then has to be supplied
#    explicitly, because commit_tree_from_wt_head calls git commit-tree
#    without one.
#
# Usage: fm-ci-codebase-lane.sh --lane <lane> | --family <family> | --check-coverage
set -eu

case "${1:-}" in
  ''|-h|--help)
    sed -n '2,26p' "${BASH_SOURCE[0]}"
    exit 0
    ;;
esac

id -u ci >/dev/null 2>&1 || useradd -m -s /bin/bash ci
chown -R ci:ci .

runuser -u ci -- env HOME=/home/ci PATH="/opt/node22/bin:$PATH" \
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
  GIT_AUTHOR_NAME="firstmate ci" GIT_AUTHOR_EMAIL=ci@firstmate.invalid \
  GIT_COMMITTER_NAME="firstmate ci" GIT_COMMITTER_EMAIL=ci@firstmate.invalid \
  bash -c '
    set -eu
    [ "$(id -u)" -ne 0 ] || { echo "suite must not run as root"; exit 1; }
    node --version
    exec bin/fm-test-run.sh "$@"
  ' fm-ci-codebase-lane "$@"
