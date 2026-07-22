#!/usr/bin/env bash
# Deterministic evaluator for the fleet-flow-finalization unattended LAB batch.
# It accepts only one exact copied artifact as the workload side effect, then
# validates that artifact with the external finance-harness v2 installation.
set -euo pipefail

usage() {
  echo "usage: evaluate-finance-batch.sh snapshot PROJECT OUTPUT BASELINE" >&2
  echo "       evaluate-finance-batch.sh evaluate PROJECT INPUT OUTPUT TRUSTED_SOURCES MARKET_MARK BASELINE BASELINE_SHA256" >&2
  exit 2
}

fail_usage() {
  echo "error: $1" >&2
  exit 2
}

canonical_dir() {
  [ -d "$1" ] || fail_usage "directory does not exist: $1"
  (cd "$1" && pwd -P)
}

canonical_file() {
  [ ! -L "$1" ] || fail_usage "symlinks are not allowed: $1"
  [ -f "$1" ] || fail_usage "regular file is required: $1"
  local parent base
  parent=$(canonical_dir "$(dirname "$1")")
  base=$(basename "$1")
  printf '%s/%s\n' "$parent" "$base"
}

canonical_candidate() {
  [ ! -L "$1" ] || fail_usage "symlinks are not allowed: $1"
  [ ! -e "$1" ] || fail_usage "path must not already exist: $1"
  local parent base
  parent=$(canonical_dir "$(dirname "$1")")
  base=$(basename "$1")
  printf '%s/%s\n' "$parent" "$base"
}

path_hash() {
  printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
}

file_hash() {
  shasum -a 256 "$1" | awk '{print $1}'
}

tree_hash() {
  perl -MDigest::SHA -MFile::Find -e '
    use strict;
    use warnings;
    my $exclude = shift @ARGV;
    my @records;
    while (@ARGV) {
      my $label = shift @ARGV;
      my $root = shift @ARGV;
      find({
        no_chdir => 1,
        wanted => sub {
          my $path = $File::Find::name;
          return if $label eq "project" && $path eq $exclude;
          my @st = lstat($path);
          die "lstat $path: $!\n" unless @st;
          my $rel = $path eq $root ? "." : substr($path, length($root) + 1);
          my $kind;
          if (-f _) {
            open my $fh, "<", $path or die "open $path: $!\n";
            binmode $fh;
            $kind = "f:" . Digest::SHA->new(256)->addfile($fh)->hexdigest;
            close $fh or die "close $path: $!\n";
          } elsif (-d _) {
            $kind = "d";
          } elsif (-l _) {
            my $target = readlink($path);
            die "readlink $path: $!\n" unless defined $target;
            $kind = "l:" . unpack("H*", $target);
          } else {
            $kind = "o:" . $st[6];
          }
          push @records, join("\0", $label, unpack("H*", $rel),
            sprintf("%o", $st[2]), $st[4], $st[5], $kind) . "\0";
        }
      }, $root);
    }
    my $sha = Digest::SHA->new(256);
    $sha->add($_) for sort @records;
    print $sha->hexdigest, "\n";
  ' "$@"
}

git_paths() {
  GIT_DIR_REAL=$(git -C "$PROJECT_REAL" rev-parse --path-format=absolute --git-dir)
  GIT_COMMON_REAL=$(git -C "$PROJECT_REAL" rev-parse --path-format=absolute --git-common-dir)
  GIT_DIR_REAL=$(canonical_dir "$GIT_DIR_REAL")
  GIT_COMMON_REAL=$(canonical_dir "$GIT_COMMON_REAL")
  HEAD_OID=$(git -C "$PROJECT_REAL" rev-parse --verify 'HEAD^{commit}')
}

manifest_hash() {
  if [ "$GIT_DIR_REAL" = "$GIT_COMMON_REAL" ]; then
    tree_hash "$OUTPUT_REAL" project "$PROJECT_REAL" git "$GIT_DIR_REAL"
  else
    tree_hash "$OUTPUT_REAL" project "$PROJECT_REAL" git-dir "$GIT_DIR_REAL" git-common "$GIT_COMMON_REAL"
  fi
}

require_outside_project() {
  case "$1" in
    "$PROJECT_REAL"|"$PROJECT_REAL"/*) fail_usage "baseline must be outside the assigned project" ;;
  esac
}

require_fixture_file() {
  local path
  path=$(canonical_file "$1")
  case "$path" in
    "$PROJECT_REAL"/*) printf '%s\n' "$path" ;;
    *) fail_usage "evaluator input escaped the assigned project: $path" ;;
  esac
}

write_snapshot() {
  [ "$#" -eq 3 ] || usage
  PROJECT_REAL=$(canonical_dir "$1")
  OUTPUT_REAL=$(canonical_candidate "$2")
  BASELINE_REAL=$(canonical_candidate "$3")
  require_outside_project "$BASELINE_REAL"
  [ "$OUTPUT_REAL" = "$PROJECT_REAL/out/result.json" ] \
    || fail_usage "output must be PROJECT/out/result.json"
  git_paths
  case "$BASELINE_REAL" in
    "$GIT_DIR_REAL"|"$GIT_DIR_REAL"/*|"$GIT_COMMON_REAL"|"$GIT_COMMON_REAL"/*)
      fail_usage "baseline must be outside Git metadata"
      ;;
  esac
  local snapshot
  snapshot=$(manifest_hash)
  (
    umask 077
    set -C
    {
      printf 'fleet-finance-baseline-v1\n'
      printf 'project=%s\n' "$(path_hash "$PROJECT_REAL")"
      printf 'output=%s\n' "$(path_hash "$OUTPUT_REAL")"
      printf 'git_dir=%s\n' "$(path_hash "$GIT_DIR_REAL")"
      printf 'git_common=%s\n' "$(path_hash "$GIT_COMMON_REAL")"
      printf 'head=%s\n' "$HEAD_OID"
      printf 'manifest=%s\n' "$snapshot"
    } > "$BASELINE_REAL"
  ) || fail_usage "could not create baseline: $BASELINE_REAL"
  file_hash "$BASELINE_REAL"
}

baseline_value() {
  sed -n "s/^$1=//p" "$BASELINE_REAL"
}

read_snapshot() {
  [ "$(wc -l < "$BASELINE_REAL" | tr -d ' ')" = 7 ] \
    || fail_usage "baseline has an invalid record count"
  [ "$(sed -n '1p' "$BASELINE_REAL")" = fleet-finance-baseline-v1 ] \
    || fail_usage "baseline has an invalid schema"
  BASELINE_PROJECT=$(baseline_value project)
  BASELINE_OUTPUT=$(baseline_value output)
  BASELINE_GIT_DIR=$(baseline_value git_dir)
  BASELINE_GIT_COMMON=$(baseline_value git_common)
  BASELINE_HEAD=$(baseline_value head)
  BASELINE_MANIFEST=$(baseline_value manifest)
  for value in "$BASELINE_PROJECT" "$BASELINE_OUTPUT" "$BASELINE_GIT_DIR" \
    "$BASELINE_GIT_COMMON" "$BASELINE_HEAD" "$BASELINE_MANIFEST"; do
    case "$value" in
      *[!0-9a-f]*|'') fail_usage "baseline contains an invalid value" ;;
    esac
  done
  [ "${#BASELINE_PROJECT}" -eq 64 ] \
    && [ "${#BASELINE_OUTPUT}" -eq 64 ] \
    && [ "${#BASELINE_GIT_DIR}" -eq 64 ] \
    && [ "${#BASELINE_GIT_COMMON}" -eq 64 ] \
    && [ "${#BASELINE_MANIFEST}" -eq 64 ] \
    || fail_usage "baseline contains an invalid digest"
  [ "${#BASELINE_HEAD}" -eq 40 ] || [ "${#BASELINE_HEAD}" -eq 64 ] \
    || fail_usage "baseline contains an invalid HEAD"
}

evaluate_batch() {
  [ "$#" -eq 7 ] || usage
  PROJECT_REAL=$(canonical_dir "$1")
  INPUT_REAL=$(require_fixture_file "$2")
  OUTPUT_REAL=$(require_fixture_file "$3")
  TRUSTED_REAL=$(require_fixture_file "$4")
  MARKET_REAL=$(require_fixture_file "$5")
  BASELINE_REAL=$(canonical_file "$6")
  BASELINE_SEAL=$7
  require_outside_project "$BASELINE_REAL"
  [ "$OUTPUT_REAL" = "$PROJECT_REAL/out/result.json" ] \
    || fail_usage "output must be PROJECT/out/result.json"
  [ ! "$INPUT_REAL" -ef "$OUTPUT_REAL" ] \
    || fail_usage "input and output must not alias the same file"
  case "$BASELINE_SEAL" in
    *[!0-9a-f]*|'') fail_usage "baseline SHA-256 is invalid" ;;
  esac
  [ "${#BASELINE_SEAL}" -eq 64 ] || fail_usage "baseline SHA-256 is invalid"
  [ "$(file_hash "$BASELINE_REAL")" = "$BASELINE_SEAL" ] \
    || { echo "error: baseline changed after the trusted snapshot" >&2; exit 1; }
  git_paths
  read_snapshot
  [ "$(path_hash "$PROJECT_REAL")" = "$BASELINE_PROJECT" ] \
    && [ "$(path_hash "$OUTPUT_REAL")" = "$BASELINE_OUTPUT" ] \
    && [ "$(path_hash "$GIT_DIR_REAL")" = "$BASELINE_GIT_DIR" ] \
    && [ "$(path_hash "$GIT_COMMON_REAL")" = "$BASELINE_GIT_COMMON" ] \
    || fail_usage "baseline does not describe this project"
  [ "$HEAD_OID" = "$BASELINE_HEAD" ] \
    || { echo "error: repository HEAD changed after the trusted snapshot" >&2; exit 1; }
  [ "$(manifest_hash)" = "$BASELINE_MANIFEST" ] \
    || { echo "error: workload side effects differ from the one allowed output" >&2; exit 1; }
  cmp -s "$INPUT_REAL" "$OUTPUT_REAL" \
    || { echo "error: output is not the exact approved artifact" >&2; exit 1; }

  local finance_harness_home trusted_sha market_sha validation
  finance_harness_home=${FINANCE_HARNESS_HOME:-}
  [ -n "$finance_harness_home" ] || fail_usage "FINANCE_HARNESS_HOME is required"
  [ -x "$finance_harness_home/bin/finance-axi" ] || fail_usage "finance-axi is not executable"
  trusted_sha=$(shasum -a 256 "$TRUSTED_REAL" | awk '{print $1}')
  market_sha=$(shasum -a 256 "$MARKET_REAL" | awk '{print $1}')
  validation=$(
    "$finance_harness_home/bin/finance-axi" validate \
      --artifact "$OUTPUT_REAL" \
      --profile valuation-extract \
      --contract-id example-valuation \
      --trusted-sources "$TRUSTED_REAL" \
      --trusted-sources-sha256 "$trusted_sha" \
      --market-mark-input "$MARKET_REAL" \
      --market-mark-input-sha256 "$market_sha" \
      --format json
  )

  printf '%s\n' "$validation" | jq -e -s '
    length == 1
    and (.[0] | type == "object")
    and (.[0] | has("ok") and (.ok | type == "boolean") and .ok == true)
    and (.[0] | has("profile") and (.profile | type == "string") and .profile == "valuation-extract")
    and (.[0] | has("summary") and (.summary | type == "object"))
    and (.[0].summary | has("errors") and (.errors | type == "number") and .errors == 0)
    and (.[0].summary | has("warnings") and (.warnings | type == "number") and .warnings == 0)
    and (.[0] | has("diagnostics") and (.diagnostics | type == "array") and (.diagnostics | length) == 0)
  ' >/dev/null

  cat <<'EOF'
EVALUATOR=finance-harness-v2
artifact_cmp=pass
finance_ok=true
errors=0
warnings=0
side_effects=out/result.json
verdict=success
EOF
}

[ "$#" -ge 1 ] || usage
mode=$1
shift
case "$mode" in
  snapshot) write_snapshot "$@" ;;
  evaluate) evaluate_batch "$@" ;;
  *) usage ;;
esac
