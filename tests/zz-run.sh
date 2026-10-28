#!/usr/bin/env bash
src=$(sed '/^test_[a-z_]*$/,$d' "$(dirname "$0")/fm-pr-check-security.test.sh")
eval "$src"
test_arming_baselines_an_already_degraded_change
