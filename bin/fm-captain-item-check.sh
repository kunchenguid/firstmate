#!/usr/bin/env bash
# fm-captain-item-check.sh - pre-surface guard for captain-facing risk and decision items.
#
# WHY THIS EXISTS: a risk label, an internal mechanism, and a failure mode do
# not give the captain enough information to weigh a tradeoff or correct a bad
# premise.
# A promise to write more clearly is not enforcement, so this check refuses an
# item until it names the system's purpose, the business impact, both sides of
# the cost tradeoff, and the exact decision being requested in plain language.
#
# A risk or decision file contains exactly one plain-language wrapper with
# these level-two sections, in order:
#
#   ## System and purpose
#   ## Business impact
#   ## Decision requested
#
# It may then carry an exact technical finding without forcing that finding to
# become the captain-facing explanation:
#
#   ## Verbatim technical finding
#   <!-- fm-verbatim:start -->
#   <unaltered finding>
#   <!-- fm-verbatim:end -->
#
# The wrapper is checked and the delimited finding is deliberately excluded
# from prose checks.
# A Lavish request is the exact assembly accepted by request mode: one or more
# individually valid items, no other prose, each enclosed in these markers:
#
#   <!-- fm-captain-item: risk -->
#   <one complete item>
#   <!-- /fm-captain-item -->
#
# Use `decision` instead of `risk` in the opening marker when applicable.
# Request mode checks the assembly and every enclosed item.
# `lavish-axi create` snapshots the request bytes once, runs request mode on
# that snapshot, and stores those same bytes so checked and surfaced content
# cannot diverge.
#
# Usage:
#   fm-captain-item-check.sh <risk|decision|request> <file>
#
# Exit 0 = clear to surface.
# Exit 1 = hard draft failure; fix every reported element first.
# Exit 2 = invalid mode or unreadable file.
set -uo pipefail

MODE=${1:-}
FILE=${2:-}
SELF=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/${0##*/}

case "$MODE" in
  risk|decision|request) ;;
  *)
    printf 'usage: %s <risk|decision|request> <file>\n' "${0##*/}" >&2
    exit 2
    ;;
esac

[ -n "$FILE" ] && [ -r "$FILE" ] || {
  printf 'captain-item-check: error: unreadable item file: %s\n' "$FILE" >&2
  exit 2
}

check_request() {
  local temporary manifest parse_error parse_rc request_failed mode item item_number output
  temporary=$(mktemp -d "${TMPDIR:-/tmp}/fm-captain-item-check.XXXXXX") || exit 2
  manifest="$temporary/manifest.tsv"
  parse_error="$temporary/parse-error"
  : > "$manifest"
  : > "$parse_error"

  awk -v output="$temporary" -v manifest="$manifest" -v error_file="$parse_error" '
    function refuse(message) {
      if (!failed) print message > error_file
      failed = 1
      exit 1
    }
    /^<!-- fm-captain-item: (risk|decision) -->$/ {
      if (inside) refuse("nested item marker")
      inside = 1
      count += 1
      mode = $0
      sub(/^<!-- fm-captain-item: /, "", mode)
      sub(/ -->$/, "", mode)
      item = sprintf("%s/item-%06d.md", output, count)
      print mode "\t" item >> manifest
      next
    }
    /^<!-- \/fm-captain-item -->$/ {
      if (!inside) refuse("closing marker without an open item")
      inside = 0
      close(item)
      next
    }
    /fm-captain-item/ {
      refuse("malformed item marker")
    }
    inside {
      print > item
      next
    }
    $0 !~ /^[[:space:]]*$/ {
      refuse("unchecked prose outside item markers")
    }
    END {
      if (failed) exit 1
      if (inside) refuse("item marker is not closed")
      if (count == 0) refuse("request contains no checked items")
    }
  ' "$FILE"
  parse_rc=$?
  if [ "$parse_rc" -ne 0 ]; then
    printf 'captain-item-check: FAIL (mode=request, file=%s)\n' "$FILE"
    printf '  invalid: request-assembly - %s\n' "$(cat "$parse_error")"
    rm -rf "$temporary"
    return 1
  fi

  request_failed=0
  item_number=0
  while IFS=$'\t' read -r mode item; do
    item_number=$((item_number + 1))
    output="$temporary/item-$item_number.output"
    if ! "$SELF" "$mode" "$item" > "$output"; then
      request_failed=1
      printf 'captain-item-check: item %s (%s) failed\n' "$item_number" "$mode"
      sed 's/^/  /' "$output"
    fi
  done < "$manifest"

  if [ "$request_failed" -ne 0 ]; then
    printf 'captain-item-check: FAIL (mode=request, file=%s)\n' "$FILE"
    rm -rf "$temporary"
    return 1
  fi

  printf 'captain-item-check: CLEAR (mode=request, file=%s, items=%s)\n' \
    "$FILE" "$item_number"
  rm -rf "$temporary"
}

if [ "$MODE" = request ]; then
  check_request
  exit $?
fi

failures=''

add_failure() {
  failures="${failures}${1}"$'\n'
}

heading_count() {
  local heading=$1
  printf '%s\n' "$CHECK_TEXT" \
    | awk -v heading="$heading" '$0 == heading { count += 1 } END { print count + 0 }'
}

section_body() {
  local heading=$1
  printf '%s\n' "$CHECK_TEXT" | awk -v heading="$heading" '
    $0 == heading { inside = 1; next }
    inside && /^## / { exit }
    inside { print }
  '
}

word_count() {
  awk '{ count += NF } END { print count + 0 }'
}

check_section() {
  local heading=$1 element=$2 description=$3 minimum_words=$4 count body words
  count=$(heading_count "$heading")
  if [ "$count" -eq 0 ]; then
    add_failure "missing: $element - $description"
    return
  fi
  if [ "$count" -ne 1 ]; then
    add_failure "invalid: $element - heading must appear exactly once"
    return
  fi
  body=$(section_body "$heading")
  words=$(printf '%s\n' "$body" | word_count)
  if [ "$words" -lt "$minimum_words" ]; then
    add_failure "thin: $element - $description must be substantive (found $words words, need at least $minimum_words)"
  fi
}

if grep -Fxq '## Verbatim technical finding' "$FILE"; then
  CHECK_TEXT=$(awk '$0 == "## Verbatim technical finding" { exit } { print }' "$FILE")
  if ! awk '
    $0 == "<!-- fm-verbatim:start -->" {
      if (state != 0) exit 1
      state = 1
      next
    }
    $0 == "<!-- fm-verbatim:end -->" {
      if (state != 1) exit 1
      state = 2
      next
    }
    state == 1 {
      if ($0 !~ /^[[:space:]]*$/) content = 1
      next
    }
    $0 == "## Verbatim technical finding" {
      heading = 1
      next
    }
    heading && $0 !~ /^[[:space:]]*$/ { exit 1 }
    END {
      if (!heading || state != 2 || !content) exit 1
    }
  ' "$FILE"; then
    add_failure 'invalid: verbatim-block - place one nonempty finding between the exact documented markers with no prose outside them'
  fi
else
  CHECK_TEXT=$(cat "$FILE")
  if grep -q 'fm-verbatim:' "$FILE"; then
    add_failure 'invalid: verbatim-block - marker requires the documented Verbatim technical finding heading'
  fi
fi

check_section '## System and purpose' \
  'system-purpose' 'what the system does and why it exists' 12
check_section '## Business impact' \
  'business-impact' 'what breaks and which customers or business outcome feel it' 12
check_section '## Decision requested' \
  'decision' 'the specific call the captain is making' 8

headings=$(printf '%s\n' "$CHECK_TEXT" | awk '/^## / { print }')
expected_headings=$(cat <<'EOF'
## System and purpose
## Business impact
## Decision requested
EOF
)
if [ "$headings" != "$expected_headings" ]; then
  add_failure 'invalid: structure - use the three required sections once each and in the documented order'
fi

if ! printf '%s\n' "$CHECK_TEXT" | awk '
  BEGIN {
    expected[1] = "## System and purpose"
    expected[2] = "## Business impact"
    expected[3] = "## Decision requested"
  }
  /^## / {
    section += 1
    if ($0 != expected[section]) exit 1
    next
  }
  section == 0 && /^# [^#]/ {
    if (title || seen_nonblank) exit 1
    title = 1
    next
  }
  section == 0 && $0 !~ /^[[:space:]]*$/ { exit 1 }
  section > 0 && /^#{1,6}[[:space:]]/ { exit 1 }
  section == 3 && decision_ended && $0 !~ /^[[:space:]]*$/ { exit 1 }
  section == 3 && /\?/ { decision_ended = 1 }
  $0 !~ /^[[:space:]]*$/ { seen_nonblank = 1 }
  END {
    if (section != 3) exit 1
  }
'; then
  add_failure 'invalid: structure - allow only one optional title, the three section bodies, and no prose after the decision question'
fi

system_body=$(section_body '## System and purpose')
if [ -n "$system_body" ] && ! printf '%s\n' "$system_body" \
  | grep -qiE '(^|[[:space:][:punct:]])(to|so|because|exists to)([[:space:][:punct:]]|$)'; then
  add_failure 'missing: system-purpose - state why the system exists, not only what it does'
fi

impact_body=$(section_body '## Business impact')
if [ -n "$impact_body" ] && ! printf '%s\n' "$impact_body" \
  | grep -qiE 'customer|shopper|merchant|buyer|subscriber|user|people|operator|team|business|Relvino'; then
  add_failure 'missing: business-impact - name who feels the failure'
fi
if [ -n "$impact_body" ] && ! printf '%s\n' "$impact_body" \
  | grep -qiE 'charge|bill|pay|lose|miss|wrong|delay|stop|fail|expose|privacy|revenue|trust|service|cashback|report|recommendation|purchase|campaign|message|harm|risk'; then
  add_failure 'missing: business-impact - name the customer or business outcome that changes'
fi

decision_body=$(section_body '## Decision requested')
if [ -n "$decision_body" ] && ! printf '%s\n' "$decision_body" | grep -q '?'; then
  add_failure 'missing: decision - ask the specific call as a question'
fi
if [ -n "$decision_body" ] && ! printf '%s\n' "$decision_body" \
  | grep -qiE 'approve|authorize|choose|decide|allow|keep|disable|accept|whether|which|should'; then
  add_failure 'missing: decision - name the action or choice being decided'
fi

# These terms are not forbidden in engineering work.
# They are refused here because an unexplained mechanism name displaces the
# captain-facing explanation this format exists to require.
for term in \
  cron guard pointer route path main branch commit 'pull request' test tests \
  'test suite' Redis ClickHouse DML TTL mutex lease feed ingest API HTTP JSON \
  SQL schema module class function method
do
  if printf '%s\n' "$CHECK_TEXT" \
    | grep -qiE "(^|[^[:alnum:]_])${term}([^[:alnum:]_]|$)"; then
    add_failure "opaque: internal term '$term' - replace it with the user-visible behavior"
  fi
done

if printf '%s\n' "$CHECK_TEXT" \
  | grep -qE '`|[[:alnum:]]_[[:alnum:]]|[[:lower:]][[:upper:]][[:alnum:]]*'; then
  add_failure 'opaque: code-shaped name - remove internal identifiers from the captain-facing item'
fi
if printf '%s\n' "$CHECK_TEXT" \
  | grep -qiE '(^|[^[:alnum:]])(PR[[:space:]]*#[0-9]+|[[:xdigit:]]{7,40}|[^[:space:]]+\.(py|sh|ts|tsx|js|json|md)(:[0-9]+)?)([^[:alnum:]]|$)'; then
  add_failure 'opaque: engineering reference - explain the business behavior instead of citing implementation evidence'
fi

if [ -n "$failures" ]; then
  printf 'captain-item-check: FAIL (mode=%s, file=%s)\n' "$MODE" "$FILE"
  printf '%s' "$failures" | while IFS= read -r failure; do
    [ -n "$failure" ] && printf '  %s\n' "$failure"
  done
  exit 1
fi

printf 'captain-item-check: CLEAR (mode=%s, file=%s)\n' "$MODE" "$FILE"
