#!/usr/bin/env bash
# Shared concrete effort vocabulary for launch and recovery.

# shellcheck disable=SC2034 # Public vocabulary consumed by launch/recovery callers.
FM_PROFILE_EFFORT_VALUES="low, medium, high, xhigh, max, ultra, dynamic"

fm_profile_effort_valid() {
  case "$1" in
    low | medium | high | xhigh | max | ultra | dynamic) return 0 ;;
  esac
  return 1
}
