#!/usr/bin/env bash
# Portability guard: every shipped bin/ script must load on bash 3.2.
#
# Stock macOS ships bash 3.2.57 as /bin/bash, and firstmate's scripts run under
# whatever bash the operator's host resolves - so a bash 4+ only construct is not
# a style problem, it is a parse error that aborts the script before its first
# line runs. bin/fm-hooks-lib.sh is sourced under 'set -eu' by fm-spawn,
# fm-teardown, fm-pr-check, fm-pr-merge and fm-merge-local, so one such construct
# in it took out spawn, teardown, PR recording, PR merge and local merge on every
# stock-macOS home at once - even a home with no hooks installed. CI and the local
# suite both run on bash 5, which parses those constructs happily, so nothing
# caught it. This does.
#
# Two layers, because the interpreter that would catch it is not everywhere:
#   (a) parse every shipped script with a real bash 3.2 when the host has one
#       (macOS /bin/bash), which is the authoritative check;
#   (b) scan for the bash 4+ only constructs regardless, so Linux CI - where no
#       3.2 interpreter exists - still fails loudly on the same regression.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The shipped surface: what an operator's host actually executes or sources.
shipped_scripts() {
  ls "$ROOT"/bin/*.sh "$ROOT"/bin/backends/*.sh 2>/dev/null
}

# Echo the path of a bash 3.2 interpreter, preferring the stock macOS one, or
# nothing when the host has none.
find_bash32() {
  local candidate
  for candidate in /bin/bash /usr/bin/bash; do
    [ -x "$candidate" ] || continue
    case "$("$candidate" --version 2>/dev/null | head -1)" in
      *"version 3.2"*) printf '%s\n' "$candidate"; return 0 ;;
    esac
  done
  printf '\n'
}

test_shipped_scripts_parse_under_bash32() {
  local bash32 script failed=""
  bash32=$(find_bash32)
  if [ -z "$bash32" ]; then
    pass "no bash 3.2 interpreter on this host; the static scan below is the guard here"
    return 0
  fi
  while IFS= read -r script; do
    "$bash32" -n "$script" 2>/dev/null || failed="$failed $script"
  done <<< "$(shipped_scripts)"
  [ -z "$failed" ] || fail "these shipped scripts do not parse under bash 3.2 ($bash32):$failed"
  pass "every shipped bin/ script parses under bash 3.2"
}

# The constructs that make a script bash 4+ only. Comment lines are exempt, so
# prose about them (this file, fm-hooks-lib.sh's header) does not trip the scan.
test_shipped_scripts_avoid_bash4_only_constructs() {
  local script hits="" found
  local -a patterns=(
    '(^|[^[:alnum:]_])coproc([[:space:]]|$)'
    '(^|[^[:alnum:]_])read([[:space:]]+-[a-zA-Z]+)*[[:space:]]+-[a-zA-Z]*N([[:space:]]|$)'
    '(^|[^[:alnum:]_])(declare|local|typeset)[[:space:]]+-[a-zA-Z]*A([[:space:]]|$)'
    '(^|[^[:alnum:]_])(mapfile|readarray)([[:space:]]|$)'
    '\$\{[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?(\^|,,|,[^,]|\^\^)'
    ';;&|;&[[:space:]]*$'
    '(^|[^[:alnum:]_>&])\|&'
    '(^|[^[:alnum:]_])wait[[:space:]]+-n([[:space:]]|$)'
  )
  local pattern
  while IFS= read -r script; do
    for pattern in "${patterns[@]}"; do
      found=$(grep -nE "$pattern" "$script" | grep -vE '^[0-9]+:[[:space:]]*#' || true)
      [ -z "$found" ] || hits="$hits
${script#"$ROOT"/}: $found"
    done
  done <<< "$(shipped_scripts)"
  [ -z "$hits" ] || fail "bash 4+ only constructs in shipped scripts (stock macOS ships bash 3.2):$hits"
  pass "no shipped bin/ script uses a bash 4+ only construct"
}

# The guard must actually catch the regression it exists for, on both layers.
test_guard_catches_a_bash4_only_construct() {
  local tmp bash32 probe
  tmp=$(fm_test_tmproot bash32-guard)
  mkdir -p "$tmp"
  probe="$tmp/probe.sh"
  cat > "$probe" <<'SH'
#!/usr/bin/env bash
{ coproc CAP { cat; } } 2>/dev/null
SH
  bash32=$(find_bash32)
  if [ -n "$bash32" ]; then
    "$bash32" -n "$probe" 2>/dev/null \
      && fail "bash 3.2 ($bash32) parsed a coproc; this guard would never catch the regression"
  fi
  grep -qE '(^|[^[:alnum:]_])coproc([[:space:]]|$)' "$probe" \
    || fail "the static scan pattern does not match a coproc"
  pass "the guard rejects a bash 4+ only construct rather than silently passing"
}

test_shipped_scripts_parse_under_bash32
test_shipped_scripts_avoid_bash4_only_constructs
test_guard_catches_a_bash4_only_construct
