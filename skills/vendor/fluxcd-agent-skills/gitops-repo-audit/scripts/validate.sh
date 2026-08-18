#!/usr/bin/env bash

# DO NOT EDIT: this file is vendored from the flux-schema action (single source of truth).
# Source: https://raw.githubusercontent.com/fluxcd/flux-schema/main/actions/validate/validate.sh

# Copyright 2026 The Flux authors. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# This script validates Kubernetes manifests using the Flux Schema CLI.
# It builds kustomize overlays and validates the output using a user-provided
# config file, or the ecosystem catalog (schemas.fluxoperator.dev) when no
# config file is found.
# Arguments after '--' are passed verbatim to 'flux-schema validate' and
# take precedence over the config file, so callers (e.g. AI agents) can
# set validation options inline without writing a config file to disk.
# The script auto-detects and excludes non-Kubernetes directories such as
# dotfiles, Terraform modules and Helm charts.
# With --helm-charts, Helm charts are rendered with 'helm template' using
# their default values and the output is validated as well.
# A build or validation failure does not stop the run; the script keeps
# going and exits non-zero at the end with the total error count.
# With --output-bundle, all standalone manifests and rendered kustomize
# overlays are merged into a single YAML file where each unit is preceded
# by a provenance comment ('# === file: <path> ===' or
# '# === kustomize-overlay: <dir> ==='), so tools and AI agents can grep
# one file instead of crawling the repository.
# This script is meant to be run locally and in CI before the changes
# are merged on the main branch that's synced by Flux.

# Prerequisites
# - flux-schema >= 0.6 (standalone binary, or the 'flux schema' plugin)
# - kustomize, or kubectl (uses its embedded kustomize via 'kubectl kustomize')
# - helm >= 4.0 (only with --helm-charts)

# Usage examples:
#   validate.sh \
#     -d ./manifests \
#     -c ./.fluxschema.yml \
#     -b ./.bundle.yaml
#
#   validate.sh -d ./manifests -- \
#     --skip-json-path=Secret:/sops \
#     --skip-missing-schemas \
#     --output=json
#
# Name the bundle with a leading dot (e.g. '.bundle.yaml') so that
# validation and 'flux-schema discover' ignore it on subsequent runs,
# as dotfiles are excluded by default.

set -o errexit
set -o pipefail

# track validation and build failures
errors=0

# running tally of resources across every flux-schema invocation, parsed
# in-memory from each run's "Summary:" line.
# summaries_parsed stays 0 when output is non-text (e.g. a '--' or config
# override to json/yaml), so the report can omit a misleading "0 valid".
valid_count=0
invalid_count=0
skipped_count=0
summaries_parsed=0

# mirror kustomize-controller build options
kustomize_flags=("--load-restrictor=LoadRestrictionsNone")
kustomize_config="kustomization.yaml"

# mirror helm-controller install options (CRDs are installed by default)
helm_flags=("--include-crds")
helm_config="Chart.yaml"

# Default flags used when no config file is found. Use the ecosystem catalog,
# strip SOPS-encrypted fields before validation (Flux removes these at apply
# time), skip documents whose schema is not in the catalog, and pin text output
# so the per-resource summary tally is parsed reliably (a config or '--'
# override owns the format).
default_flux_schema_flags=("--schema-location=ecosystem" "--skip-json-path=/sops" "--skip-missing-schemas" "--verbose" "--output=text")

# Effective flags passed to flux-schema, populated by resolve_config.
flux_schema_flags=()

# Flags given after '--', passed verbatim to 'flux-schema validate'.
# When set, they take precedence over the config file and default flags.
flux_schema_args=()

# Effective flux-schema invocation, populated by resolve_flux_schema.
# Either ("flux" "schema") for the Flux CLI plugin or ("flux-schema") for the
# standalone CLI.
flux_schema_cmd=()

# Effective kustomize invocation, populated by resolve_kustomize.
# Either ("kustomize" "build") or ("kubectl" "kustomize").
kustomize_cmd=()

# root directory to validate
root_dir="."

# path to the flux-schema config file
config_file=".fluxschema.yml"

# path to the merged YAML bundle (empty disables bundling)
bundle_file=""

# when true, render Helm charts with 'helm template' and validate the output
build_helm_charts=false

# directories to exclude from validation
exclude_dirs=()

# directories auto-detected as non-Kubernetes (terraform, helm charts)
declare -a auto_skip_dirs=()

# directories that are Helm charts
declare -a helm_chart_dirs=()

# directories that are kustomize overlays
declare -a kustomize_dirs=()

usage() {
  echo "Usage: $0 [-d <dir>] [-c <file>] [-e <dir>]... [-b <file>] [-H] [-h] [-- <flux-schema flags>]"
  echo ""
  echo "Validate Flux custom resources and kustomize overlays using flux-schema."
  echo ""
  echo "Options:"
  echo "  -d, --dir <dir>             Root directory to validate (default: current directory)"
  echo "  -c, --config <file>         Path to a flux-schema config file (default: .fluxschema.yml)."
  echo "                              When the file does not exist, sensible defaults are used."
  echo "  -e, --exclude <dir>         Directory to exclude from validation and the bundle (can be repeated)"
  echo "  -b, --output-bundle <file>  Write all standalone manifests and rendered kustomize"
  echo "                              overlays to a single YAML file with provenance comments"
  echo "  -H, --helm-charts           Render Helm charts with 'helm template' using their"
  echo "                              default values and validate the output (requires helm)"
  echo "  -h, --help                  Show this help message"
  echo "  -- <flux-schema flags>      Pass the remaining arguments verbatim to 'flux-schema validate',"
  echo "                              taking precedence over the config file and default flags"
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
      -c|--config)
        if [[ -z "${2:-}" ]]; then
          echo "ERROR - --config requires a file path argument" >&2
          exit 1
        fi
        config_file="$2"
        shift 2
        ;;
      -e|--exclude)
        if [[ -z "${2:-}" ]]; then
          echo "ERROR - --exclude requires a directory argument" >&2
          exit 1
        fi
        exclude_dirs+=("./${2#./}")
        shift 2
        ;;
      -b|--output-bundle)
        if [[ -z "${2:-}" ]]; then
          echo "ERROR - --output-bundle requires a file path argument" >&2
          exit 1
        fi
        bundle_file="$2"
        shift 2
        ;;
      -H|--helm-charts)
        build_helm_charts=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        flux_schema_args=("$@")
        break
        ;;
      *)
        echo "ERROR - Unknown argument: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
  done
}

check_prerequisites() {
  if [[ ! -d "$root_dir" ]]; then
    echo "ERROR - directory not found: $root_dir" >&2
    exit 1
  fi
  if [[ "$build_helm_charts" == true ]] && ! command -v helm &> /dev/null; then
    echo "ERROR - helm is not installed (required by --helm-charts)" >&2
    exit 1
  fi
}

# Pick the flux-schema invocation. Prefer the 'flux schema' plugin dispatch
# (the documented 'flux plugin install schema' path); fall back to a standalone
# flux-schema binary on PATH.
resolve_flux_schema() {
  if command -v flux &> /dev/null && flux schema --help &> /dev/null; then
    flux_schema_cmd=("flux" "schema")
  elif command -v flux-schema &> /dev/null; then
    flux_schema_cmd=("flux-schema")
  else
    echo "ERROR - flux-schema is not installed (tried 'flux schema' plugin and 'flux-schema')" >&2
    exit 1
  fi
}

# Pick the kustomize invocation. Prefer the standalone CLI (independently
# updatable); fall back to kubectl's embedded kustomize ('kubectl kustomize').
resolve_kustomize() {
  if command -v kustomize &> /dev/null; then
    kustomize_cmd=("kustomize" "build")
  elif command -v kubectl &> /dev/null; then
    kustomize_cmd=("kubectl" "kustomize")
  else
    echo "ERROR - neither kustomize nor kubectl is installed" >&2
    exit 1
  fi
}

# Pick the flags to pass to flux-schema. Flags given after '--' win; when
# the config file exists, defer all validation options to it; otherwise
# fall back to the built-in defaults.
resolve_config() {
  if [[ ${#flux_schema_args[@]} -gt 0 ]]; then
    echo "INFO - Using flux-schema flags from the command line"
    flux_schema_flags=("${flux_schema_args[@]}")
  elif [[ -f "$config_file" ]]; then
    echo "INFO - Using flux-schema config: $config_file"
    flux_schema_flags=("--config=$config_file")
  else
    echo "INFO - Config file '$config_file' not found, using default flags"
    flux_schema_flags=("${default_flux_schema_flags[@]}")
  fi
}

# Normalize a path by stripping leading "./" for consistent comparisons
normalize_path() {
  local p="${1#./}"
  echo "${p%/}"
}

# Create the parent directory and truncate the bundle file when
# --output-bundle is set
init_bundle() {
  if [[ -z "$bundle_file" ]]; then
    return 0
  fi
  if ! mkdir -p "$(dirname "$bundle_file")" 2>/dev/null || \
    ! : 2>/dev/null > "$bundle_file"; then
    echo "ERROR - Cannot write bundle file: $bundle_file" >&2
    exit 1
  fi
}

# Path relative to root_dir, used in bundle provenance comments to match
# the root-relative paths emitted by 'flux-schema discover'
rel_path() {
  local p r
  p="$(normalize_path "$1")"
  r="$(normalize_path "$root_dir")"
  if [[ "$r" != "." && "$p" == "$r"/* ]]; then
    p="${p#"$r"/}"
  fi
  echo "$p"
}

# Append a unit to the bundle file: a document separator, a provenance
# comment, and the YAML content read from stdin. No-op when --output-bundle
# is not set (stdin is drained so writers never see a broken pipe).
bundle_append() {
  if [[ -z "$bundle_file" ]]; then
    cat > /dev/null
    return 0
  fi
  {
    echo "---"
    echo "# === $1 ==="
    cat
  } >> "$bundle_file"
}

# Check if a path is under a user-excluded, auto-skipped, or kustomize directory
is_excluded_dir() {
  local path
  path="$(normalize_path "$1")"
  for dir in "${exclude_dirs[@]}"; do
    local d
    d="$(normalize_path "$dir")"
    if [[ "$path" == "$d"/* || "$path" == "$d" ]]; then
      return 0
    fi
  done
  for dir in "${auto_skip_dirs[@]}"; do
    local d
    d="$(normalize_path "$dir")"
    if [[ "$path" == "$d"/* || "$path" == "$d" ]]; then
      return 0
    fi
  done
  for dir in "${kustomize_dirs[@]}"; do
    local d
    d="$(normalize_path "$dir")"
    if [[ "$path" == "$d"/* || "$path" == "$d" ]]; then
      return 0
    fi
  done
  return 1
}

# Check if a path is under a user-excluded directory only
is_user_excluded_dir() {
  local path
  path="$(normalize_path "$1")"
  for dir in "${exclude_dirs[@]}"; do
    local d
    d="$(normalize_path "$dir")"
    if [[ "$path" == "$d"/* || "$path" == "$d" ]]; then
      return 0
    fi
  done
  return 1
}

# Check if a chart directory is vendored inside another chart
# (e.g. a dependency under the parent's charts/ directory); such charts
# are rendered as part of their parent and must not be templated standalone
is_nested_chart_dir() {
  local path
  path="$(normalize_path "$1")"
  for dir in "${helm_chart_dirs[@]}"; do
    local d
    d="$(normalize_path "$dir")"
    if [[ "$path" != "$d" && "$path" == "$d"/* ]]; then
      return 0
    fi
  done
  return 1
}

# Check if a path is under a user-excluded or auto-skipped directory (but not kustomize dirs)
is_non_kustomize_excluded_dir() {
  local path
  path="$(normalize_path "$1")"
  for dir in "${exclude_dirs[@]}" "${auto_skip_dirs[@]}"; do
    local d
    d="$(normalize_path "$dir")"
    if [[ "$path" == "$d"/* || "$path" == "$d" ]]; then
      return 0
    fi
  done
  return 1
}

# Detect directories containing Terraform files, Helm charts, or kustomize overlays
detect_excluded_dirs() {
  while IFS= read -r -d $'\0' file; do
    auto_skip_dirs+=("$(dirname "$file")")
  done < <(find "$root_dir" -mindepth 1 -name '.*' -prune -o -type f -name '*.tf' -print0)

  while IFS= read -r -d $'\0' file; do
    auto_skip_dirs+=("$(dirname "$file")")
    helm_chart_dirs+=("$(dirname "$file")")
  done < <(find "$root_dir" -mindepth 1 -name '.*' -prune -o -type f -name "$helm_config" -print0)

  while IFS= read -r -d $'\0' file; do
    kustomize_dirs+=("$(dirname "$file")")
  done < <(find "$root_dir" -mindepth 1 -name '.*' -prune -o -type f -name "$kustomize_config" -print0)
}

# Add a captured flux-schema run's "Summary:" counts to the running tally.
accumulate_summary() {
  if [[ "$1" =~ Valid:\ ([0-9]+),\ Invalid:\ ([0-9]+),\ Skipped:\ ([0-9]+) ]]; then
    valid_count=$((valid_count + BASH_REMATCH[1]))
    invalid_count=$((invalid_count + BASH_REMATCH[2]))
    skipped_count=$((skipped_count + BASH_REMATCH[3]))
    summaries_parsed=$((summaries_parsed + 1))
  fi
}

validate_kubernetes_manifests() {
  echo "INFO - Validating Kubernetes manifests"
  local files=() output dir
  while IFS= read -r -d $'\0' file; do
    dir="$(dirname "$file")"
    if is_excluded_dir "$dir"; then
      continue
    fi
    if [[ -n "$bundle_file" && "$file" -ef "$bundle_file" ]]; then
      continue
    fi
    files+=("$file")
  done < <(find "$root_dir" -mindepth 1 -name '.*' -prune -o -type f \( -name '*.yaml' -o -name '*.yml' \) -print0)
  if [[ ${#files[@]} -gt 0 ]]; then
    if [[ -n "$bundle_file" ]]; then
      for file in "${files[@]}"; do
        # SC2094: $file is never the bundle file (filtered above via -ef)
        # shellcheck disable=SC2094
        bundle_append "file: $(rel_path "$file")" < "$file"
      done
    fi
    # Capture stdout+stderr in memory so the run can be both printed and
    # tallied; the assignment lives in the 'if' so errexit does not fire.
    if ! output="$("${flux_schema_cmd[@]}" validate "${flux_schema_flags[@]}" "${files[@]}" 2>&1)"; then
      errors=$((errors + 1))
    fi
    printf '%s\n' "$output"
    accumulate_summary "$output"
  fi
}

validate_kustomize_overlays() {
  local overlay build_output output dir
  while IFS= read -r -d $'\0' file; do
    dir="$(dirname "$file")"
    if is_non_kustomize_excluded_dir "$dir"; then
      continue
    fi
    overlay="${file/%$kustomize_config}"
    echo "INFO - Validating kustomize overlay $overlay"
    if ! build_output=$("${kustomize_cmd[@]}" "$overlay" "${kustomize_flags[@]}"); then
      echo "ERROR - kustomize build failed for $overlay" >&2
      bundle_append "kustomize-overlay: $(rel_path "$overlay") (build failed)" < /dev/null
      errors=$((errors + 1))
      continue
    fi
    [[ -n "$bundle_file" ]] && bundle_append "kustomize-overlay: $(rel_path "$overlay")" <<< "$build_output"
    if ! output="$(printf '%s\n' "$build_output" | \
      "${flux_schema_cmd[@]}" validate "${flux_schema_flags[@]}" 2>&1)"; then
      errors=$((errors + 1))
    fi
    printf '%s\n' "$output"
    accumulate_summary "$output"
  done < <(find "$root_dir" -mindepth 1 -name '.*' -prune -o -type f -name "$kustomize_config" -print0)
}

validate_helm_charts() {
  if [[ "$build_helm_charts" != true ]]; then
    return 0
  fi
  local chart build_output output
  for chart in "${helm_chart_dirs[@]}"; do
    if is_user_excluded_dir "$chart" || is_nested_chart_dir "$chart"; then
      continue
    fi
    echo "INFO - Validating helm chart $chart"
    if ! build_output=$(helm template "$chart" "${helm_flags[@]}"); then
      echo "ERROR - helm template failed for $chart" >&2
      bundle_append "helm-chart: $(rel_path "$chart") (build failed)" < /dev/null
      errors=$((errors + 1))
      continue
    fi
    [[ -n "$bundle_file" ]] && bundle_append "helm-chart: $(rel_path "$chart")" <<< "$build_output"
    if ! output="$(printf '%s\n' "$build_output" | \
      "${flux_schema_cmd[@]}" validate "${flux_schema_flags[@]}" 2>&1)"; then
      errors=$((errors + 1))
    fi
    printf '%s\n' "$output"
    accumulate_summary "$output"
  done
}

# Print the final outcome and exit non-zero when any build or validation failed.
# The exit decision comes from the per-invocation error count (robust even if
# output is reformatted); the valid/invalid/skipped tally is parsed from the
# collected "Summary:" lines for a precise, agent-readable breakdown.
report_results() {
  if [[ -n "$bundle_file" ]]; then
    echo "INFO - Bundle written to $bundle_file"
  fi
  # Only append the resource breakdown when text Summary lines were parsed;
  # a non-text output override leaves the tally at zero, which would mislead.
  local tally=""
  if [[ $summaries_parsed -gt 0 ]]; then
    tally=" (${valid_count} valid, ${skipped_count} skipped)"
  fi
  if [[ $errors -gt 0 ]]; then
    if [[ $summaries_parsed -gt 0 ]]; then
      echo "ERROR - Validation failed: ${errors} error(s); ${invalid_count} invalid resource(s) (${valid_count} valid, ${skipped_count} skipped)" >&2
    else
      echo "ERROR - Validation failed with ${errors} error(s)" >&2
    fi
    exit 1
  fi
  echo "INFO - All validations passed${tally}"
}

# Main
parse_args "$@"
check_prerequisites
resolve_flux_schema
resolve_kustomize
resolve_config
init_bundle
detect_excluded_dirs
validate_kubernetes_manifests
validate_kustomize_overlays
validate_helm_charts
report_results
