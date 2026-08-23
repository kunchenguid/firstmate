#!/usr/bin/env bash
# fm-lint-workflows.sh - owner of firstmate's GitHub workflow lint.
#
# Runs pinned actionlint on every .github/workflows/*.{yml,yaml} so a malformed
# workflow, including a self-broken ci.yml, fails in the local and no-mistakes
# lint lane before merge. A broken ci.yml cannot report its own breakage, so
# this check must not live only as a step inside that workflow. bin/fm-lint.sh
# invokes this owner on its default (no explicit-path) path, which CI and
# commands.lint both use.
#
# The directory-scan path then checks one gating invariant across the scanned
# set: every PR base gated by any pull_request-triggered workflow must also be
# gated by no-mistakes-required.yml, so a base can never get CI without the
# check branch protection requires. See the comment above
# REQUIRED_CHECK_WORKFLOW for why that is worth enforcing mechanically.
#
# Usage:
#   fm-lint-workflows.sh                 lint workflows under this repo
#   fm-lint-workflows.sh --root <dir>    lint workflows under <dir>
#   fm-lint-workflows.sh <path>...       lint explicit workflow files
#   fm-lint-workflows.sh --required-version
#   fm-lint-workflows.sh --help
set -eu

REQUIRED_ACTIONLINT=1.7.12
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$SELF_DIR/fm-lint-workflows.sh"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

if [ "${1:-}" = "--required-version" ]; then
  printf '%s\n' "$REQUIRED_ACTIONLINT"
  exit 0
fi

fm_lint_workflows_usage() {
  sed -n '2,22{s/^# \{0,1\}//;p;}' "$SELF"
}

EXPLICIT_ROOT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || {
        printf 'fm-lint-workflows.sh: --root requires a directory.\n' >&2
        exit 2
      }
      EXPLICIT_ROOT=$2
      shift 2
      ;;
    --root=*)
      EXPLICIT_ROOT=${1#*=}
      shift
      ;;
    --help|-h)
      fm_lint_workflows_usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      printf 'fm-lint-workflows.sh: unknown option: %s\n' "$1" >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

if [ -n "$EXPLICIT_ROOT" ]; then
  [ -d "$EXPLICIT_ROOT" ] || {
    printf 'fm-lint-workflows.sh: --root is not a directory: %s\n' "$EXPLICIT_ROOT" >&2
    exit 2
  }
  ROOT="$(cd "$EXPLICIT_ROOT" && pwd)"
fi

collect_workflow_files() {
  local dir=$1
  [ -d "$dir" ] || return 0
  find "$dir" -maxdepth 1 \( -name '*.yml' -o -name '*.yaml' \) -type f \
    | LC_ALL=C sort
}

# A `pull_request` trigger's `branches` filter matches the PR BASE branch, and
# GitHub reads the workflow file from the PR merge commit rather than from the
# base tip. Two consequences make this worth a gate: a base absent from every
# filter gets no checks at all, which the pull request UI cannot distinguish
# from passing checks, and the PR that adds a base to a filter gates itself.
# Which branches deserve gating is not statically knowable, so the rule pinned
# here is the superset one: every base gated by any PR-triggered workflow must
# also be gated by the required check, so a base can never get CI without also
# getting the check branch protection requires. The reminder to add a new
# long-lived base at all lives in each workflow's own `on:` block comment.
REQUIRED_CHECK_WORKFLOW=no-mistakes-required.yml

# Prints exactly one classification line for one workflow file:
#   none                  no `pull_request` trigger
#   all                   `pull_request` with no base filter, so every base
#   bases <base>...       `pull_request` filtered to these bases
#   unsupported <reason>  a form this gate refuses to guess at
fm_lint_workflows_pr_filter() {
  awk '
function ind(s) { match(s, /^ */); return RLENGTH }
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function unq(s, q) {
  s = trim(s)
  q = "\047"
  if (length(s) >= 2) {
    if (substr(s, 1, 1) == "\"" && substr(s, length(s), 1) == "\"") \
      return substr(s, 2, length(s) - 2)
    if (substr(s, 1, 1) == q && substr(s, length(s), 1) == q) \
      return substr(s, 2, length(s) - 2)
  }
  return s
}
function emit(v) { print v; emitted = 1; exit }
function tokens(s, n, i, a, t, r) {
  gsub(/[\[\]]/, " ", s)
  gsub(/,/, " ", s)
  n = split(s, a, /[ \t]+/)
  r = ""
  for (i = 1; i <= n; i++) { t = unq(a[i]); if (t != "") r = r " " t }
  return r
}
function events(s, n, i, a) {
  n = split(tokens(s), a, / /)
  for (i = 1; i <= n; i++) if (a[i] == "pull_request") return "all"
  return "none"
}
function branch_list() {
  return bases == "" ? "unsupported empty branches list" : "bases" bases
}
{
  line = $0
  sub(/\r$/, "", line)
  sub(/[ \t]+#.*$/, "", line)
  t = trim(line)
  if (t == "" || substr(t, 1, 1) == "#") next
  i = ind(line)
  ci = index(line, ":")
  key = ""
  val = ""
  if (ci > 0) {
    key = unq(substr(line, 1, ci - 1))
    val = trim(substr(line, ci + 1))
  }
  # YAML lets a block sequence sit at the indent of its parent key, so block
  # membership rather than raw indent decides where a block ends: a `-` line at
  # or deeper than the indent of the key it belongs to is an item of that key,
  # never the next key. A mapping key always carries a `:` and never starts
  # with `-`, so the two forms never collide.
  dash = (substr(t, 1, 1) == "-")
  if (mode == 0) {
    if (i == 0 && key == "on") {
      if (substr(val, 1, 1) == "{") emit("unsupported flow-mapping on: value")
      if (val != "") emit(events(val))
      mode = 1
      on_indent = -1
    }
    next
  }
  if (mode == 3) {
    if (dash && i >= br_indent) {
      b = unq(trim(substr(t, 2)))
      if (b == "") emit("unsupported empty branches entry")
      bases = bases " " b
      next
    }
    # Anything that is not an item of this sequence ends the branches list.
    if (i <= br_indent) emit(branch_list())
    emit("unsupported non-sequence entry under branches")
  }
  if (mode == 1) {
    # The first member line decides whether on: holds a sequence or a mapping;
    # under a mapping, deeper `-` lines belong to some other event key.
    if (on_indent < 0) {
      on_indent = i
      if (dash) seq = 1
    }
    if (seq) {
      if (dash && i >= on_indent) {
        ev = ev " " unq(trim(substr(t, 2)))
        next
      }
      # on: sits at column 0, so only a column-0 key can end its block; a
      # shallower-but-not-top-level line is mixed content this gate refuses.
      if (i == 0) emit(events(ev))
      emit("unsupported mixed sequence in on: block")
    }
    # A top-level key ends the on: block, so the verdict is whatever we have.
    if (i == 0) emit("none")
    if (i != on_indent || key != "pull_request") next
    if (val != "") emit("unsupported inline pull_request value")
    mode = 2
    pr_indent = -1
    next
  }
  # The pull_request block ended without a branches filter: every base.
  if (i <= on_indent) emit("all")
  if (pr_indent < 0) {
    if (dash) emit("unsupported sequence under pull_request")
    pr_indent = i
  }
  if (i != pr_indent) next
  if (key == "branches-ignore") \
    emit("unsupported branches-ignore under pull_request")
  if (key != "branches") next
  if (val == "") {
    mode = 3
    br_indent = i
    next
  }
  if (substr(val, 1, 1) == "[") {
    if (index(val, "]") == 0) \
      emit("unsupported multi-line flow sequence under branches")
    bases = tokens(val)
    emit(branch_list())
  }
  emit("unsupported scalar branches value")
}
END {
  if (emitted) exit
  if (mode == 0) emit("unsupported no top-level on: key")
  if (seq) emit(events(ev))
  if (mode == 1) emit("none")
  if (mode == 2) emit("all")
  emit(branch_list())
}
' "$1"
}

# Compares the scanned workflow set against REQUIRED_CHECK_WORKFLOW. Runs only
# on the directory-scan path, because the invariant is a property of the whole
# workflow set rather than of one explicitly linted file.
fm_lint_workflows_pr_gating() {
  local file name verdict required_verdict='' required_set='' found_required=0
  local rc=0 i n base missing
  local names=() verdicts=()

  for file in "${FILES[@]}"; do
    name=${file##*/}
    verdict=$(fm_lint_workflows_pr_filter "$file") || {
      printf 'fm-lint-workflows.sh: %s: could not be read for its pull_request base filter.\n' \
        "$name" >&2
      return 1
    }
    case "$verdict" in
      "unsupported "*)
        printf 'fm-lint-workflows.sh: %s: cannot read the pull_request base filter (%s). Keep the on: block in block style with an explicit branches: list, or teach this gate the new form.\n' \
          "$name" "${verdict#unsupported }" >&2
        return 1
        ;;
    esac
    if [ "$name" = "$REQUIRED_CHECK_WORKFLOW" ]; then
      found_required=1
      required_verdict=$verdict
      continue
    fi
    names+=("$name")
    verdicts+=("$verdict")
  done

  n=${#names[@]}
  if [ "$found_required" -eq 0 ]; then
    # A deleted required check is exactly the failure this gate exists to catch:
    # no checks at all reads like passing checks in the pull request UI. Its
    # absence is only acceptable when nothing in the set gates pull requests.
    missing=''
    i=0
    while [ "$i" -lt "$n" ]; do
      name=${names[$i]}
      verdict=${verdicts[$i]}
      i=$((i + 1))
      [ "$verdict" != none ] || continue
      missing="$missing $name"
    done
    if [ -n "$missing" ]; then
      printf 'fm-lint-workflows.sh: %s is absent from this workflow set while%s gate(s) pull requests, so every PR base they gate can merge with no required check. Restore %s with a pull_request trigger covering those bases.\n' \
        "$REQUIRED_CHECK_WORKFLOW" "$missing" "$REQUIRED_CHECK_WORKFLOW" >&2
      return 1
    fi
    printf 'fm-lint-workflows.sh: PR base gating: no workflow in this set has a pull_request trigger, so %s is not needed here.\n' \
      "$REQUIRED_CHECK_WORKFLOW" >&2
    return 0
  fi
  if [ "$required_verdict" = none ]; then
    printf 'fm-lint-workflows.sh: %s has no pull_request trigger, so the required check can never run. Restore its pull_request trigger and base list.\n' \
      "$REQUIRED_CHECK_WORKFLOW" >&2
    return 1
  fi
  case "$required_verdict" in
    bases*) required_set="${required_verdict#bases} " ;;
  esac

  i=0
  while [ "$i" -lt "$n" ]; do
    name=${names[$i]}
    verdict=${verdicts[$i]}
    i=$((i + 1))
    [ "$verdict" != none ] || continue
    [ "$required_verdict" != all ] || continue
    if [ "$verdict" = all ]; then
      printf 'fm-lint-workflows.sh: %s gates every PR base while %s requires checks only on:%s. Drop the base filter in %s or widen it there.\n' \
        "$name" "$REQUIRED_CHECK_WORKFLOW" "${required_verdict#bases}" \
        "$REQUIRED_CHECK_WORKFLOW" >&2
      rc=1
      continue
    fi
    missing=''
    # Intentional word split: the classifier emits bases separated by spaces.
    for base in ${verdict#bases}; do
      case "$required_set" in
        *" $base "*) ;;
        *) missing="$missing $base" ;;
      esac
    done
    if [ -n "$missing" ]; then
      printf 'fm-lint-workflows.sh: %s gates PR base(s)%s that %s does not require, so a PR into them can merge with the required check absent. Add them to %s.\n' \
        "$name" "$missing" "$REQUIRED_CHECK_WORKFLOW" "$REQUIRED_CHECK_WORKFLOW" >&2
      rc=1
    fi
  done

  [ "$rc" -eq 0 ] || return 1
  if [ "$required_verdict" = all ]; then
    printf 'fm-lint-workflows.sh: PR base gating: %s requires checks on every PR base\n' \
      "$REQUIRED_CHECK_WORKFLOW"
  else
    printf 'fm-lint-workflows.sh: PR base gating: %s requires checks on:%s\n' \
      "$REQUIRED_CHECK_WORKFLOW" "${required_verdict#bases}"
  fi
}

FILES=()
SCAN_MODE=0
if [ "$#" -gt 0 ]; then
  for path in "$@"; do
    case "$path" in
      *.yml|*.yaml) ;;
      *)
        printf 'fm-lint-workflows.sh: not a workflow YAML file: %s\n' "$path" >&2
        exit 2
        ;;
    esac
    [ -f "$path" ] || {
      printf 'fm-lint-workflows.sh: workflow file not found: %s\n' "$path" >&2
      exit 2
    }
    FILES+=("$path")
  done
else
  SCAN_MODE=1
  workflow_dir="$ROOT/.github/workflows"
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    FILES+=("$path")
  done < <(collect_workflow_files "$workflow_dir")
  if [ "${#FILES[@]}" -eq 0 ]; then
    printf 'fm-lint-workflows.sh: no GitHub workflow files found under %s\n' \
      "$workflow_dir" >&2
    exit 1
  fi
fi

if ! command -v actionlint >/dev/null 2>&1; then
  printf 'fm-lint-workflows.sh: actionlint not found; install actionlint %s with bin/fm-install-actionlint.sh <destination-directory> and put that directory on PATH.\n' \
    "$REQUIRED_ACTIONLINT" >&2
  exit 1
fi
ACTIONLINT_BIN=$(command -v actionlint)
resolved=$("$ACTIONLINT_BIN" -version | awk 'NR==1 {print; exit}')
printf 'fm-lint-workflows.sh: actionlint %s (pinned %s)\n' "$resolved" "$REQUIRED_ACTIONLINT" >&2
if [ "$resolved" != "$REQUIRED_ACTIONLINT" ]; then
  printf 'fm-lint-workflows.sh: actionlint %s required for CI parity, found %s. Install %s with bin/fm-install-actionlint.sh <destination-directory>.\n' \
    "$REQUIRED_ACTIONLINT" "$resolved" "$REQUIRED_ACTIONLINT" >&2
  exit 1
fi

# fm-lint.sh owns ShellCheck of the canonical shell set. Disable actionlint's
# extra shell and Python subprocess linters so this gate is the named workflow
# linter, not a second shell lint of `run:` blocks.
set +e
"$ACTIONLINT_BIN" -no-color -shellcheck= -pyflakes= -- "${FILES[@]}"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  exit "$rc"
fi

printf 'fm-lint-workflows.sh: %s workflow files valid\n' "${#FILES[@]}"

if [ "$SCAN_MODE" -eq 1 ]; then
  fm_lint_workflows_pr_gating || exit 1
fi
exit 0
