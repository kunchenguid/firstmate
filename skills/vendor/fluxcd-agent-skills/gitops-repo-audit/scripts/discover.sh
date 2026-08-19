#!/usr/bin/env bash

# Copyright 2026 The Flux authors. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# This script scans a directory for Kubernetes and Flux resources using the
# flux-schema plugin and outputs a structured JSON inventory: directory
# classification (manifests, kustomize-overlay, helm-chart, terraform),
# Flux resources listed per file, and Kubernetes resource counts by kind.

# Prerequisites
# - flux-schema, available either as a standalone binary on PATH or as a plugin
#   (install with: flux plugin install schema)

set -o errexit
set -o pipefail

root_dir="."
skip_files=()

# command used to invoke flux-schema, resolved by check_prerequisites
flux_schema=()

usage() {
  echo "Usage: $0 [-d <dir>] [-e <name>]... [-h]"
  echo ""
  echo "Discover Kubernetes resources and output a JSON inventory report."
  echo ""
  echo "Options:"
  echo "  -d, --dir <dir>       Root directory to scan (default: current directory)"
  echo "  -e, --exclude <name>  File or directory basename glob to skip (can be repeated)"
  echo "  -h, --help            Show this help message"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--dir)
        if [[ -z "${2:-}" ]]; then
          echo "ERROR - --dir requires a directory argument" >&2
          exit 1
        fi
        root_dir="${2%/}"
        shift 2
        ;;
      -e|--exclude)
        if [[ -z "${2:-}" ]]; then
          echo "ERROR - --exclude requires an argument" >&2
          exit 1
        fi
        skip_files+=("$(basename "${2%/}")")
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        echo "ERROR - Unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

# Minimum flux-schema version required by this skill.
readonly MIN_FLUX_SCHEMA_VERSION="0.10.0"

# Return 0 if semver $1 is >= $2. Compares the numeric major.minor.patch
# fields; inputs are validated x.y.z strings, so no external tools are needed.
version_ge() {
  local a="$1" b="$2" i x y
  local -a af bf
  IFS='.' read -r -a af <<< "$a"
  IFS='.' read -r -a bf <<< "$b"
  for i in 0 1 2; do
    x="${af[i]:-0}"
    y="${bf[i]:-0}"
    if (( 10#$x > 10#$y )); then return 0; fi
    if (( 10#$x < 10#$y )); then return 1; fi
  done
  return 0
}

# Resolve how to invoke flux-schema: prefer the 'flux schema' plugin dispatch,
# otherwise fall back to a standalone flux-schema binary on PATH.
check_prerequisites() {
  if command -v flux &> /dev/null && flux schema version &> /dev/null; then
    flux_schema=(flux schema)
  elif command -v flux-schema &> /dev/null; then
    flux_schema=(flux-schema)
  else
    echo "ERROR - flux-schema is not installed" >&2
    echo "ERROR - Install it with: flux plugin install schema" >&2
    exit 1
  fi

  local version
  version="$("${flux_schema[@]}" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  if [[ -z "$version" ]]; then
    echo "ERROR - unable to determine the flux-schema version" >&2
    exit 1
  fi
  if ! version_ge "$version" "$MIN_FLUX_SCHEMA_VERSION"; then
    echo "ERROR - flux-schema v${version} is too old; this skill requires ${MIN_FLUX_SCHEMA_VERSION} or later" >&2
    echo "ERROR - Upgrade it with: flux plugin install schema" >&2
    exit 1
  fi
}

discover() {
  local args=("$root_dir" "-o" "json")
  for pattern in "${skip_files[@]}"; do
    args+=("--skip-file" "$pattern")
  done
  "${flux_schema[@]}" discover "${args[@]}"
}

# Main
parse_args "$@"
check_prerequisites
discover
