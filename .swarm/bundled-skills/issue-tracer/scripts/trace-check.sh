#!/usr/bin/env bash
# trace-check.sh - read-only validation for issue-tracer v3 evidence.
set -eu
export LC_ALL=C

to_shell_path() {
  case "$(uname -s 2>/dev/null || true)" in
    MINGW* | MSYS* | CYGWIN*)
      if command -v cygpath >/dev/null 2>&1; then cygpath -u "$1"; return; fi
      ;;
  esac
  printf '%s\n' "$1"
}

root="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "trace-check: not inside a git work tree" >&2; exit 2; }
root="$(to_shell_path "$root")"
root_real="$(cd "$root" && pwd -P)"
issue_traces_base="$root_real/.agents/issue-traces"
script_dir="$(cd "$(dirname "$0")" && pwd -P)"
failed=0
legacy=0
trace_root_real=""

usage() { echo "usage: trace-check.sh {tree-id|handshake|phase <phase> --slug <slug> [--trace-dir <dir>]|merge --slug <slug>}" >&2; exit 2; }
valid_slug() { case "$1" in ''|*[!a-z0-9-]*) return 1;; *) return 0;; esac; }
trim() { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
has_bad_control() {
  # Shell variables can carry newlines, but grep treats them as record
  # separators; reject those explicitly before scanning the remaining bytes.
  case "$1" in *$'\t'*|*$'\n'*|*$'\r'*) return 0;; esac
  local matches
  # grep -c drains stdin. A terminal grep -q can make printf receive SIGPIPE
  # under inherited pipefail, turning a real control byte into a false miss.
  matches="$(LC_ALL=C printf '%s' "$1" | LC_ALL=C grep -c '[[:cntrl:]]' || true)"
  [ "${matches:-0}" -gt 0 ]
}

# Markdown trace artifacts are commonly authored on Windows.  Keep every
# line-oriented parser below independent of the file's record separator while
# preserving embedded control bytes for the explicit validation paths.
normalize_terminal_cr() { sed 's/\r$//' "$1"; }

# Validate the caller-selected trace directory before opening state.md.  The
# lexical prefix check rejects absolute escapes and dot components before any
# canonicalization (which would otherwise turn an escaped path back into an
# apparently safe one).  The deepest existing ancestor and each existing
# component are then checked for symlinks/junctions so a path that looks inside
# the root cannot redirect reads outside it.
validate_trace_dir() {
  local candidate="$1" check parent resolved canonical_candidate
  has_bad_control "$candidate" && { echo "trace-check: --trace-dir cannot contain control bytes" >&2; exit 2; }
  candidate="$(to_shell_path "$candidate")"
  has_bad_control "$candidate" && { echo "trace-check: --trace-dir cannot contain control bytes" >&2; exit 2; }
  case "$candidate/" in
    */../*|*/./*|*\\*) echo "trace-check: --trace-dir cannot contain . or .. components or backslashes" >&2; exit 2;;
  esac
  # Inspect the caller's spelling before the alias fallback canonicalizes it.
  # Otherwise a symlink/junction that resolves back inside the trace root would
  # disappear from the later component walk and be accepted as a safe path.
  check="$candidate"
  while :; do
    if [ -L "$check" ]; then
      echo "trace-check: refusing symlinked trace component: $check" >&2
      exit 2
    fi
    [ "$check" = "/" ] && break
    parent="$(dirname "$check")"
    [ "$parent" != "$check" ] || break
    check="$parent"
  done
  case "$candidate/" in
    "$root_real/.agents/issue-traces/"*) ;;
    *)
      # Windows may preserve an 8.3 alias (for example RUNNER~1) in the
      # caller's absolute path while Git resolves the repository through its
      # long spelling. Resolve an existing explicit directory before rejecting
      # it, while retaining the lexical traversal/backslash rejection above.
      canonical_candidate="$(cd "$candidate" 2>/dev/null && pwd -P)" || {
        echo "trace-check: --trace-dir must be inside .agents/issue-traces" >&2
        exit 2
      }
      case "$canonical_candidate/" in
        "$root_real/.agents/issue-traces/"*) candidate="$canonical_candidate" ;;
        *) echo "trace-check: --trace-dir must be inside .agents/issue-traces" >&2; exit 2;;
      esac
      ;;
  esac

  check="$candidate"
  while [ -L "$check" ]; do
    echo "trace-check: refusing symlinked trace path: $candidate" >&2
    exit 2
  done
  while [ ! -e "$check" ]; do
    parent="$(dirname "$check")"
    [ "$parent" != "$check" ] || break
    check="$parent"
    [ -L "$check" ] || continue
    echo "trace-check: refusing symlinked trace ancestor: $check" >&2
    exit 2
  done
  [ -e "$check" ] || { echo "trace-check: could not resolve trace path: $candidate" >&2; exit 2; }
  resolved="$(cd "$check" 2>/dev/null && pwd -P)" || { echo "trace-check: could not resolve trace path: $candidate" >&2; exit 2; }
  case "$resolved/" in
    "$root_real/"*) ;;
    *) echo "trace-check: --trace-dir resolves outside the project root" >&2; exit 2;;
  esac

  check="$candidate"
  while [ "$check" != "$root_real" ] && [ "$check" != "/" ]; do
    if [ -L "$check" ]; then
      echo "trace-check: refusing symlinked trace component: $check" >&2
      exit 2
    fi
    check="$(dirname "$check")"
  done
  [ "$check" = "$root_real" ] || { echo "trace-check: --trace-dir is not rooted at the project" >&2; exit 2; }
}

# Validate a path below the already-canonical trace root immediately before it
# is read.  `[ -f ]` follows symlinks, so it cannot be used as the first check:
# a leaf or an intermediate directory could redirect an otherwise in-root
# artifact to an arbitrary outside file.  The ancestor walk catches both POSIX
# symlinks and Windows junctions as reported by MSYS `test -L`; the canonical
# parent check is defense in depth for filesystem races and unusual link forms.
trace_path_safe() {
  local path="$1" kind="${2:-file}" ancestor parent resolved
  [ -n "$trace_root_real" ] || { echo "trace-check: trace root is not initialized" >&2; exit 2; }
  case "$path/" in
    "$trace_root_real/"*) ;;
    *) echo "trace-check: refusing path outside canonical trace root: $path" >&2; exit 2;;
  esac
  case "$path/" in
    */../*|*/./*|*\\*) echo "trace-check: refusing ambiguous trace path: $path" >&2; exit 2;;
  esac
  ancestor="$path"
  while [ "$ancestor" != "$trace_root_real" ] && [ "$ancestor" != "/" ]; do
    if [ -L "$ancestor" ]; then
      echo "trace-check: refusing symlinked trace component: $ancestor" >&2
      exit 2
    fi
    ancestor="$(dirname "$ancestor")"
  done
  [ "$ancestor" = "$trace_root_real" ] || { echo "trace-check: trace path is not rooted at the canonical trace directory: $path" >&2; exit 2; }
  [ "$path" = "$trace_root_real" ] && { [ "$kind" = dir ] && [ -d "$path" ]; return $?; }
  parent="$(dirname "$path")"
  [ -d "$parent" ] || return 1
  resolved="$(cd "$parent" 2>/dev/null && pwd -P)" || { echo "trace-check: could not resolve trace artifact parent: $path" >&2; exit 2; }
  case "$resolved/" in
    "$trace_root_real/"*) ;;
    *) echo "trace-check: trace artifact parent resolves outside canonical trace root: $path" >&2; exit 2;;
  esac
  case "$kind" in
    file) [ -f "$path" ] || return 1;;
    dir) [ -d "$path" ] || return 1;;
    *) echo "trace-check: internal invalid trace path kind: $kind" >&2; exit 2;;
  esac
}

tree_id() {
  # Trace artifacts under .agents/issue-traces/ must never affect this
  # identity. trace-init.sh writes that directory to info/exclude, but that
  # entry is an unenforced convention, so after staging the working tree
  # (tracked + untracked-not-ignored, exactly like `git add -A .`) the trace
  # directory is removed from the temporary index explicitly. Never use
  # `add -f` here: it would stage gitignored content (node_modules, build
  # output), making the identity machine-specific and writing ignored blobs
  # into the real object store.
  local index
  index="$(mktemp "${TMPDIR:-/tmp}/issue-tracer-index.XXXXXX")"
  rm -f "$index"
  if ! GIT_INDEX_FILE="$index" git -C "$root" read-tree HEAD \
    || ! GIT_INDEX_FILE="$index" git -C "$root" add -A -- . \
    || ! GIT_INDEX_FILE="$index" git -C "$root" rm -r --cached --ignore-unmatch -q -- .agents/issue-traces \
    || ! GIT_INDEX_FILE="$index" git -C "$root" write-tree; then
    rm -f "$index"
    return 1
  fi
  rm -f "$index"
}

handshake() {
  local version candidate value shim verdict worst="MATCH"
  version="$(awk '{ sub(/\r$/, "", $0) } /^metadata:/{in_metadata=1; next} in_metadata && /^  version:/{sub(/^  version:[[:space:]]*/, ""); print; exit}' "$root/.opencode/skills/issue-tracer/SKILL.md" 2>/dev/null || true)"
  [ -n "$version" ] || version="unknown"
  for candidate in "${HOME:-}/.claude/skills/issue-tracer/SKILL.md" "${HOME:-}/.codex/skills/issue-tracer/SKILL.md" "${HOME:-}/.agents/skills/issue-tracer/SKILL.md" "${HOME:-}/.zcode/skills/issue-tracer/SKILL.md"; do
    if [ ! -f "$candidate" ]; then
      verdict="ABSENT"
    else
      value="$(normalize_terminal_cr "$candidate" 2>/dev/null | grep -m1 '^  version:' | sed 's/^  version:[[:space:]]*//' || true)"
      shim="$(normalize_terminal_cr "$candidate" 2>/dev/null | grep -m1 '^shim:' | sed 's/^shim:[[:space:]]*//' || true)"
      if [ "$value" = "$version" ] && [ "$shim" = "true" ]; then verdict="SHIM"
      elif [ "$value" = "$version" ]; then verdict="MATCH"
      else verdict="STALE:$candidate"; fi
    fi
    echo "handshake: $verdict $candidate"
    case "$verdict" in
      STALE:*) worst="$verdict" ;;
      ABSENT) case "$worst" in STALE:*) ;; *) worst="ABSENT";; esac ;;
      SHIM) if [ "$worst" = "MATCH" ]; then worst="SHIM"; fi ;;
    esac
  done
  echo "handshake-summary: $worst"
}

rule_ok() { echo "OK $1"; }
rule_bad() {
  if [ "$legacy" -eq 1 ]; then echo "WARN $1: $2"; else echo "FAIL $1: $2"; failed=1; fi
}
state_lines() {
  trace_path_safe "$state" file || return 0
  normalize_terminal_cr "$state"
}
state_value() {
  trace_path_safe "$state" file || return 0
  state_lines | awk -F ': ' -v key="$1" '$1 == key { print substr($0, length(key) + 3); exit }' 2>/dev/null || true
}
is_hex() { case "$1" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) return 0;; *) return 1;; esac; }

check_headings() {
  local file="$1"; shift
  if ! trace_path_safe "$file" file; then rule_bad "artifact-$(basename "$file")" "missing"; return; fi
  local heading count
  for heading in "$@"; do
    count="$(awk -v want="$heading" '{ sub(/\r$/, "", $0); if ($0 == want) n++ } END { print n + 0 }' "$file" 2>/dev/null)"
    if [ "$count" -eq 1 ]; then rule_ok "heading-${heading#\#\# }"
    elif [ "$count" -gt 1 ]; then rule_bad "duplicate-heading-${heading#\#\# }" "in $(basename "$file")"
    else rule_bad "heading-${heading#\#\# }" "missing in $(basename "$file")"; fi
  done
  # Any duplicated level-two heading is invalid even when it is not required.
  while IFS= read -r heading; do rule_bad "duplicate-heading-${heading#\#\# }" "in $(basename "$file")"; done < <(awk '{ sub(/\r$/, "", $0); if ($0 ~ /^## /) print }' "$file" 2>/dev/null | sort | uniq -d)
}

# Parse the `## Gates` table row-by-row (split on '|', trim each cell) and
# return success (0) iff a row exists whose gate/verdict/commit/treeid all
# match. An empty commit/treeid argument means "don't filter on that column".
# An unanchored substring match here previously let a DISAPPROVED row satisfy
# an APPROVE gate, since "APPROVE|RECORDED" as a regex also matches
# "DISAPPROVED"; matching is done cell-by-cell after trimming instead.
gate_row_exists() {
  local gate="$1" verdict_want="$2" commit="$3" treeid="$4" line g v c t
  trace_path_safe "$state" file || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '|'*) ;; *) continue;; esac
    IFS='|' read -r _ g v c t _ <<EOF
$line
EOF
    g="$(trim "$g")"; v="$(trim "$v")"; c="$(trim "$c")"; t="$(trim "$t")"
    [ "$g" = "$gate" ] || continue
    [ "$v" = "$verdict_want" ] || continue
    [ -z "$commit" ] || [ "$c" = "$commit" ] || continue
    [ -z "$treeid" ] || [ "$t" = "$treeid" ] || continue
    return 0
  done < <(state_lines)
  return 1
}

state_gate() {
  local gate="$1" verdict_want="$2" commit="$3" treeid="$4"
  gate_row_exists "$gate" "$verdict_want" "$commit" "$treeid" && rule_ok "gate-$gate" || rule_bad "gate-$gate" "missing approved bound row"
}

# Extract the section starting at a `## <heading>` line up to (but not
# including) the next `## ` heading or EOF, then require EXACTLY one verdict
# line in the section, and that line must be `APPROVE` or `Verdict: APPROVE`.
# Blank lines and template-guidance lines (starting with `[`) are ignored.
# Any additional verdict line - bare or `Verdict: X` - for NEEDS_REVISION,
# BLOCKED, DISAPPROVED, or REJECTED fails the section even if an APPROVE line
# is also present, so a stray leftover verdict cannot be shadowed by a later
# APPROVE.
artifact_verdict_approved() {
  local file="$1"
  trace_path_safe "$file" file || return 1
  awk '
    { sub(/\r$/, "", $0) }
    /^## Verdict$/ { infield = 1; next }
    /^## / { infield = 0 }
    infield {
      line = $0
      sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
      if (line == "") next
      if (line ~ /^\[.*\]$/) next
      verdict = line
      if (line ~ /^Verdict: /) { sub(/^Verdict: /, "", verdict) }
      else if (line !~ /^[A-Z_-]+$/) { next }
      if (verdict == "APPROVE" || verdict == "NEEDS_REVISION" || verdict == "BLOCKED" || verdict == "DISAPPROVED" || verdict == "REJECTED") {
        count++
        if (verdict == "APPROVE") { approve_count++ } else { other_count++ }
      } else {
        unknown_count++
      }
    }
    END { exit !(count == 1 && approve_count == 1 && other_count == 0 && unknown_count == 0) }
  ' "$file" 2>/dev/null
}

# Extract the `## Reviewed SHA / diff hash` section from an artifact and
# require exactly one line matching `reviewed-commit: <40hex>` and exactly
# one matching `tree-id: <40hex>`. Sets ARTIFACT_COMMIT / ARTIFACT_TREE
# (empty unless exactly one matching line was found) and
# ARTIFACT_COMMIT_COUNT / ARTIFACT_TREE_COUNT (the actual match counts, so
# callers can distinguish "0 matches" from "duplicate matches").
artifact_identity() {
  local file="$1" section
  trace_path_safe "$file" file || return 1
  section="$(awk '
    { sub(/\r$/, "", $0) }
    /^## Reviewed SHA \/ diff hash$/ { infield = 1; next }
    /^## / { infield = 0 }
    infield { print }
  ' "$file" 2>/dev/null || true)"
  local commit_matches tree_matches
  # Count every prefixed line (well-formed or not) so a malformed duplicate
  # such as "reviewed-commit: stale" cannot hide behind one valid line; the
  # sole surviving line must then be well-formed to yield a value.
  commit_matches="$(printf '%s\n' "$section" | grep -E '^reviewed-commit:' || true)"
  tree_matches="$(printf '%s\n' "$section" | grep -E '^tree-id:' || true)"
  ARTIFACT_COMMIT_COUNT="$(printf '%s\n' "$commit_matches" | grep -c . || true)"
  ARTIFACT_TREE_COUNT="$(printf '%s\n' "$tree_matches" | grep -c . || true)"
  ARTIFACT_COMMIT=""
  ARTIFACT_TREE=""
  if [ "$ARTIFACT_COMMIT_COUNT" -eq 1 ] && printf '%s\n' "$commit_matches" | grep -Eq '^reviewed-commit: [0-9a-f]{40}$'; then
    ARTIFACT_COMMIT="$(printf '%s\n' "$commit_matches" | sed 's/^reviewed-commit: //')"
  fi
  if [ "$ARTIFACT_TREE_COUNT" -eq 1 ] && printf '%s\n' "$tree_matches" | grep -Eq '^tree-id: [0-9a-f]{40}$'; then
    ARTIFACT_TREE="$(printf '%s\n' "$tree_matches" | sed 's/^tree-id: //')"
  fi
}

# Require the artifact's own `## Reviewed SHA / diff hash` identity to equal
# the expected commit/tree-id (the same values state_gate was called with for
# this phase), AND require a `<gate> | APPROVE | <expected-commit> |
# <expected-tree>` row to exist in the ledger. Checking only "the first
# APPROVE row for this gate" here (regardless of which commit/tree it names)
# previously let a STALE re-review row satisfy a CURRENT artifact and vice
# versa, once the append-only re-review path produced two APPROVE rows for
# the same gate.
artifact_identity_matches_gate() {
  local file="$1" gate="$2" expected_commit="$3" expected_treeid="$4"
  artifact_identity "$file"
  if [ "$ARTIFACT_COMMIT_COUNT" -ne 1 ] || [ "$ARTIFACT_TREE_COUNT" -ne 1 ]; then
    rule_bad "artifact-identity-$gate" "expected exactly one reviewed-commit and one tree-id line"
  elif [ -n "$ARTIFACT_COMMIT" ] && [ "$ARTIFACT_COMMIT" = "$expected_commit" ] \
    && [ -n "$ARTIFACT_TREE" ] && [ "$ARTIFACT_TREE" = "$expected_treeid" ] \
    && gate_row_exists "$gate" APPROVE "$expected_commit" "$expected_treeid"; then
    rule_ok "artifact-identity-$gate"
  else
    rule_bad "artifact-identity-$gate" "$(basename "$file") reviewed-commit/tree-id does not match the current $gate gate row"
  fi
}

recurrence_justification_ok() {
  local file="$1"
  trace_path_safe "$file" file || return 1
  awk '
    { sub(/\r$/, "", $0) }
    /^## Justification$/ { infield = 1; next }
    /^## / { infield = 0 }
    infield {
      line = $0
      sub(/^[[:space:]]+/, "", line); sub(/[[:space:]]+$/, "", line)
      if (line == "") next
      if (line ~ /^\[.*\]$/) next
      found = 1
    }
    END { exit !found }
  ' "$file" 2>/dev/null
}

clean_tree() {
  local dirty
  dirty="$(git -C "$root" status --porcelain | awk '$0 !~ /^.. \.agents\/issue-traces\//')"
  [ -z "$dirty" ] && rule_ok clean-tree || rule_bad clean-tree "working tree has non-trace changes"
}

phase0() {
  local keys key expected actual previous=0 line fresh
  trace_path_safe "$state" file || return
  keys='protocol phase tier classification base-ref base-sha freshness phase0-tree-id checkpoint-tree-id handshake tools merge next-action'
  for key in $keys; do
    line="$(state_lines | grep -n "^$key: " | cut -d: -f1 | head -n1 || true)"
    if [ -z "$line" ]; then rule_bad "state-$key" "missing"; continue; fi
    if [ "$(state_lines | grep -c "^$key: " || true)" -ne 1 ]; then rule_bad "state-$key" "must appear once"; fi
    if [ "$line" -le "$previous" ]; then rule_bad "state-order" "$key is out of order"; fi
    previous="$line"
  done
  [ "$(state_value protocol)" = "3.0.0" ] && rule_ok protocol || rule_bad protocol "expected 3.0.0"
  is_hex "$(state_value base-sha)" && rule_ok base-sha || rule_bad base-sha "must be 40 hex"
  is_hex "$(state_value phase0-tree-id)" && rule_ok phase0-tree-id || rule_bad phase0-tree-id "must be 40 hex"
  # Accept only these exact forms:
  #   synced                                            -> OK
  #   behind:<n>                                        -> FAIL (must sync first)
  #   fetch-failed:<reason> user-override:"<non-empty>"  -> OK (explicit override)
  #   fetch-failed:<reason>                              -> FAIL (fail closed)
  #   user-override:"<non-empty>"                        -> OK (standalone override)
  #   anything else                                      -> FAIL (unknown value)
  fresh="$(state_value freshness)"
  case "$fresh" in
    unset|'') rule_bad freshness "must be recorded" ;;
    synced) rule_ok freshness ;;
    behind:*) rule_bad freshness "behind, sync before proceeding" ;;
    fetch-failed:*)
      # Fully anchored: fetch-failed:<reason, no spaces/quotes> user-override:"<non-empty>"
      # and nothing else trailing. An unanchored match previously let trailing
      # garbage after a valid override slip through as OK.
      if printf '%s' "$fresh" | grep -Eq '^fetch-failed:[^[:space:]"]+ user-override:"[^"]+"$'; then
        rule_ok freshness
      else
        rule_bad freshness-fail-closed "fetch failure lacks user override"
      fi
      ;;
    user-override:*)
      if printf '%s' "$fresh" | grep -Eq '^user-override:"[^"]+"$'; then
        rule_ok freshness
      else
        rule_bad freshness "unknown value"
      fi
      ;;
    *) rule_bad freshness "unknown value" ;;
  esac
  case "$(state_value tier)" in S|M|L) rule_ok tier;; *) rule_bad tier "must be S, M, or L";; esac
  [ "$(state_value handshake)" != "unset" ] && [ -n "$(state_value handshake)" ] && rule_ok handshake || rule_bad handshake "must be recorded"
}

acceptance_ids() {
  local file="$trace/01-issue-summary.md"
  sed 's/\r$//' "$file" 2>/dev/null | grep -E '^- \[[ x]\] AC[0-9]+:' | sed -E 's/^- \[[ x]\] (AC[0-9]+):.*/\1/'
}

# Return normalized acceptance-table rows as tab-separated cells. The table is
# intentionally tolerant of LF or CRLF line endings, but never of an embedded
# control byte: strip only the record-ending CR before validating cells. Shape
# and control validation happen in this complete pass before phase25 uses AC,
# check, argv, expect, or notes in rule names/messages.
acceptance_table_header() {
  awk '
    { sub(/\r$/, "", $0) }
    /^## Acceptance checks$/ { in_table = 1; next }
    /^## / { if (in_table) in_table = 0 }
    in_table && $0 == "| AC | class | check | argv | expect | pre-fix | post-fix | notes |" { found = 1 }
    END { exit !found }
  ' "$1"
}
acceptance_table_rows() {
  awk -F '|' '
    { sub(/\r$/, "", $0) }
    /^## Acceptance checks$/ { in_table = 1; next }
    /^## / { if (in_table) in_table = 0 }
    !in_table { next }
    $0 == "| AC | class | check | argv | expect | pre-fix | post-fix | notes |" { header = 1; next }
    /^\|[-|[:space:]]+\|[[:space:]]*$/ { next }
    /^\|[[:space:]]*AC[0-9]+[[:space:]]*\|/ {
      # The leading and trailing delimiters make a valid row exactly ten
      # fields. Do not inspect or interpolate any cell until this is true.
      if (NF != 10) { bad_shape = 1; next }
      for (i = 2; i <= 9; i++) {
        cell = $i
        sub(/^[ \t]+/, "", cell)
        sub(/[ \t]+$/, "", cell)
        if (cell ~ /[[:cntrl:]]/) { bad_control = 1 }
        cells[i] = cell
      }
      print cells[2] "\t" cells[3] "\t" cells[4] "\t" cells[5] "\t" cells[6] "\t" cells[7] "\t" cells[8] "\t" cells[9]
      count += 1
      next
    }
    /^\|/ { bad_shape = 1 }
    END {
      if (!header || bad_shape || bad_control || count == 0) exit 1
    }
  ' "$1"
}
is_already_fixed() { [ "$(state_value classification)" = "ALREADY_FIXED" ]; }

phase1() {
  local file="$trace/01-issue-summary.md" value acceptance_count classification_count
  check_headings "$file" '## Source' '## Observed Behavior' '## Expected Behavior' '## Acceptance Criteria' '## Classification' '## Related Issues'
  trace_path_safe "$file" file || return
  acceptance_count="$(acceptance_ids | grep -c . || true)"
  [ "${acceptance_count:-0}" -gt 0 ] && rule_ok acceptance-criteria || rule_bad acceptance-criteria "missing AC checkbox"
  value="$(state_value classification)"
  case "$value" in VALID|AMBIGUOUS|ALREADY_FIXED|NOT_A_BUG|FEATURE) ;; *) rule_bad classification "invalid state value"; return;; esac
  classification_count="$(normalize_terminal_cr "$file" | grep -A100 '^## Classification$' | grep -c "$value" || true)"
  if normalize_terminal_cr "$file" | grep -A100 '^## Classification$' | grep -Eq 'VALID|AMBIGUOUS|ALREADY_FIXED|NOT_A_BUG|FEATURE' && [ "${classification_count:-0}" -gt 0 ]; then rule_ok classification
  else rule_bad classification "artifact does not match state"; fi
}

phase2() {
  local file="$trace/02-reproduction.md" text_block_count
  check_headings "$file" '## Commands Tried' '## Reproduction Verdict'
  trace_path_safe "$file" file || return
  text_block_count="$(normalize_terminal_cr "$file" | grep -c '^```text$' || true)"
  [ "${text_block_count:-0}" -gt 0 ] && rule_ok reproduction-text-block || rule_bad reproduction-text-block "missing"
  normalize_terminal_cr "$file" | grep -Eq '^- Exit code: [0-9]+' && rule_ok reproduction-exit-code || rule_bad reproduction-exit-code "missing"
  if is_already_fixed; then check_headings "$file" '## Fixing Change'; fi
}

phase25() {
  local file="$trace/02-reproduction.md" header ac row found class check argv expect pre post notes reason checkpoint manifest_path diff_path duplicate_check rows summary_ids
  if is_already_fixed; then rule_ok obe-subset; return; fi
  check_headings "$file" '## Commands Tried' '## Reproduction Verdict'
  trace_path_safe "$file" file || return
  header='| AC | class | check | argv | expect | pre-fix | post-fix | notes |'
  acceptance_table_header "$file" && rule_ok acceptance-table || { rule_bad acceptance-table "missing exact header"; return; }
  if ! rows="$(acceptance_table_rows "$file")"; then
    rule_bad acceptance-table "each row must have exactly 10 pipe columns and no control bytes"
    return
  fi
  # Keep Phase 2.5 bound to the same semantic verifier used at Phase 4. The
  # helper is read-only: it validates the manifest and acceptance table, and
  # does not invoke trace-check, so calling it through bash cannot recurse or
  # introduce checkpoint side effects.
  if bash "$script_dir/repro-check.sh" verify-semantics --slug "$slug" --trace-dir "$trace" >/dev/null 2>&1; then
    rule_ok acceptance-manifest-semantics
  else
    rule_bad acceptance-manifest-semantics "acceptance table semantics do not match checkpoint manifest"
  fi
  while IFS= read -r ac; do
    found=0
    while IFS=$'\t' read -r row_ac _ _ _ _ _ _ _; do
      [ "$row_ac" = "$ac" ] && found=$((found + 1))
    done <<EOF
$rows
EOF
    [ "$found" -eq 1 ] && rule_ok "acceptance-$ac" || rule_bad "acceptance-$ac" "must appear exactly once"
  done < <(acceptance_ids)
  summary_ids="$(acceptance_ids)"
  while IFS=$'\t' read -r row_ac _ _ _ _ _ _ _; do
    [ -n "$row_ac" ] || continue
    found=0
    while IFS= read -r ac; do
      [ "$row_ac" = "$ac" ] && found=1
    done <<EOF
$summary_ids
EOF
    [ "$found" -eq 1 ] || rule_bad "acceptance-$row_ac" "table row is absent from issue summary"
  done <<EOF
$rows
EOF
  duplicate_check="$(printf '%s\n' "$rows" | awk -F '\t' '{ if (++seen[$3] > 1 && duplicate == "") duplicate = $3 } END { if (duplicate != "") print duplicate }')"
  check="$duplicate_check"
  [ -z "$check" ] && rule_ok acceptance-check-ids || rule_bad acceptance-check-ids "duplicate check id $check"
  while IFS=$'\t' read -r ac class check argv expect pre post notes; do
    [ -n "$ac" ] || continue
    case "$class" in
      DISCRIMINATING) [ "$pre" = RED ] || rule_bad "pre-fix-$ac" "DISCRIMINATING must be RED"; trace_path_safe "$trace/repro/$check.base.log" file || rule_bad "base-log-$check" "missing or unsafe" ;;
      PRESERVING) [ "$pre" = GREEN ] || rule_bad "pre-fix-$ac" "PRESERVING must be GREEN"; trace_path_safe "$trace/repro/$check.base.log" file || rule_bad "base-log-$check" "missing or unsafe" ;;
      NEW-SURFACE) [ "$pre" = ERROR ] || rule_bad "pre-fix-$ac" "NEW-SURFACE must be ERROR"; trace_path_safe "$trace/repro/$check.base.log" file || rule_bad "base-log-$check" "missing or unsafe" ;;
      NON-EXECUTABLE) case "$check" in DOCS_ONLY|HOST_ONLY|PRODUCT_DECISION|EXTERNAL_SERVICE_UNAVAILABLE) ;; *) rule_bad "non-executable-$ac" "unknown reason";; esac; [ -n "$notes" ] && [ "$notes" != '-' ] || rule_bad "notes-$ac" "required" ;;
      *) rule_bad "class-$ac" "invalid" ;;
    esac
  done <<EOF
$rows
EOF
  check_headings "$file" '## Red checkpoint'
  checkpoint="$(awk '/^checkpoint-tree-id: / { sub(/\r$/, "", $0); sub(/^checkpoint-tree-id: /, ""); print; exit }' "$file" 2>/dev/null)"
  is_hex "$checkpoint" && [ "$checkpoint" = "$(state_value checkpoint-tree-id)" ] && rule_ok red-checkpoint || rule_bad red-checkpoint "state binding missing or invalid"
  manifest_path="$trace/repro/checkpoint.manifest"
  trace_path_safe "$trace/repro" dir || { rule_bad checkpoint-manifest "missing or unsafe repro directory"; return; }
  # Header shape only - repro-check.sh owns full validation (row count, seq
  # run, field count). The `rows=<N>` suffix is required, matching the fact
  # that repro-check refuses a header with no count; awk rather than a
  # `head | grep -q` pipeline so no SIGPIPE can decide the verdict, and the
  # END guard makes an empty manifest fail instead of vacuously passing.
  trace_path_safe "$manifest_path" file && awk 'NR == 1 { sub(/\r$/, "", $0); if ($0 ~ /^# issue-tracer checkpoint manifest v1 rows=[0-9]+$/) exit 0; exit 1 } END { if (NR == 0) exit 1 }' "$manifest_path" && rule_ok checkpoint-manifest || { rule_bad checkpoint-manifest "missing or invalid"; return; }
  # A checkpoint tree has one effective blob per path. Multiple acceptance
  # checks may share a path when they captured identical bytes; those rows can
  # be deduplicated while deriving the tree. Divergent effective blobs for one
  # path are unsafe, however, and must fail before the tree/path comparison can
  # accidentally treat the manifest as a path-only set.
  if awk -F '\t' '
    NR > 1 {
      if ($3 ~ /[[:cntrl:]]/) { bad = 1; next }
      pair = length($3) ":" $3 ":" $6
      latest_path[pair] = $3
      latest_blob[pair] = $4
    }
    END {
      for (pair in latest_path) {
        path = latest_path[pair]
        if (seen[path] && blob[path] != latest_blob[pair]) {
          print "conflicting effective blobs for " path > "/dev/stderr"
          bad = 1
        }
        seen[path] = 1
        blob[path] = latest_blob[pair]
      }
      exit bad
    }
  ' "$manifest_path"; then
    rule_ok manifest-effective-blobs
  else
    rule_bad manifest-effective-blobs "same path has divergent effective blobs"
    return
  fi
  diff_path="$(git diff-tree -r --name-only "$(state_value phase0-tree-id)" "$checkpoint" 2>/dev/null || true)"
  while IFS= read -r check; do
    [ -z "$check" ] && continue
    awk -F '\t' -v p="$check" 'NR > 1 && $3 == p {found=1} END {exit !found}' "$manifest_path" && rule_ok "manifest-path-$check" || rule_bad "manifest-path-$check" "not recorded"
  done <<EOF
$diff_path
EOF
}

phase3() {
  local head tid
  check_headings "$trace/05-fix-plan.md" '## Selected Fix' '## Candidate Fixes' '## Impact Analysis' '## Anticipated Defect-Class Sweep (Phase 4.2)'
  check_headings "$trace/06-critic-review.md" '## Reviewed SHA / diff hash' '## Verdict' '## Check replay'
  trace_path_safe "$trace/05-fix-plan.md" file || return
  trace_path_safe "$trace/06-critic-review.md" file || return
  awk '{ sub(/\r$/, "", $0); if ($0 ~ /^## Round [0-9]+$/) found=1 } END { exit !found }' "$trace/06-critic-review.md" 2>/dev/null && rule_ok heading-round || rule_bad heading-round "missing ## Round N heading in $(basename "$trace/06-critic-review.md")"
  artifact_verdict_approved "$trace/06-critic-review.md" && rule_ok critic-verdict || rule_bad critic-verdict "06-critic-review.md Verdict section must be exactly APPROVE"
  trace_path_safe "$trace/07-approved-plan.md" file && rule_ok approved-plan || rule_bad approved-plan "missing or unsafe"
  # The checkpoint tree may be dirty relative to HEAD at Phase 3 (the fix is
  # not implemented yet), so the plan-critic gate row is bound to the current
  # HEAD commit and the current working-tree identity (tree_id), not the
  # frozen checkpoint-tree-id.
  head="$(git rev-parse HEAD)"; tid="$(tree_id)"
  state_gate plan-critic APPROVE "$head" "$tid"
  artifact_identity_matches_gate "$trace/06-critic-review.md" plan-critic "$head" "$tid"
}

executable_ids() {
  local file="$trace/02-reproduction.md"
  normalize_terminal_cr "$file" | grep -E '^\|[[:space:]]*AC[0-9]+[[:space:]]*\|' | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $3); gsub(/^[ \t]+|[ \t]+$/, "", $4); if ($3 != "NON-EXECUTABLE") print $4}'
}
manifest_has_check_id() {
  local manifest="$1" want="$2"
  trace_path_safe "$manifest" file || return 1
  awk -F '\t' -v want="$want" '
    NR > 1 { latest[length($3) ":" $3 ":" $6] = $6 }
    END { for (pair in latest) if (latest[pair] == want) found = 1; exit !found }
  ' "$manifest"
}

# Validate one recorded replay block against the acceptance table and the
# checkpoint manifest. Presence of `### Check C1` alone is not evidence: the
# block must carry the base/head SHA, exit status, result, verdict, and the two
# replay logs produced by `repro-check.sh run`. The result pair is checked
# against the row's class and the post-fix column, so a fabricated narrative
# cannot turn Phase 4 green without real replay artifacts.
phase4_check_evidence() {
  local file="$1" id="$2" rows row class expect post block base_line head_line
  local base_sha head_sha manifest_base base_exit head_exit base_result head_result verdict
  rows="$(acceptance_table_rows "$trace/02-reproduction.md")" || {
    rule_bad acceptance-table "missing or malformed acceptance table"
    return
  }
  row="$(printf '%s\n' "$rows" | awk -F '\t' -v want="$id" '$3 == want { print; exit }')"
  [ -n "$row" ] || { rule_bad "check-evidence-$id" "missing acceptance row"; return; }
  IFS=$'\t' read -r _ class _ _ expect _ post _ <<EOF
$row
EOF
  [ "$post" = GREEN ] || rule_bad "post-fix-$id" "acceptance row must record post-fix GREEN"

  block="$(normalize_terminal_cr "$file" | awk -v marker="### Check $id" '
    ($0 == marker || index($0, marker " (") == 1) { found += 1; in_block = 1; next }
    in_block && /^### Check / { exit }
    in_block { print }
    END { if (found != 1) exit 1 }
  ')" || {
    rule_bad "check-evidence-$id" "must contain exactly one complete replay block"
    return
  }
  base_line="$(printf '%s\n' "$block" | awk '/^- base: / { print; exit }')"
  head_line="$(printf '%s\n' "$block" | awk '/^- head: / { print; exit }')"
  verdict="$(printf '%s\n' "$block" | awk '/^- verdict: / { sub(/^- verdict: /, ""); print; exit }')"
  if ! printf '%s\n' "$base_line" | grep -Eq "^- base: [0-9a-f]{40} exit=[0-9]+ result=(RED|GREEN|ERROR|FAIL|TIMEOUT|VACUOUS) log=repro/${id}\.base\.log$"; then
    rule_bad "base-evidence-$id" "missing bound base SHA, exit, result, or replay log"
    return
  fi
  if ! printf '%s\n' "$head_line" | grep -Eq "^- head: [0-9a-f]{40} exit=[0-9]+ result=(RED|GREEN|ERROR|FAIL|TIMEOUT|VACUOUS) log=repro/${id}\.head\.log$"; then
    rule_bad "head-evidence-$id" "missing bound head SHA, exit, result, or replay log"
    return
  fi
  [ "$verdict" = PASS ] || { rule_bad "verdict-$id" "replay verdict must be PASS"; return; }

  base_sha="$(printf '%s\n' "$base_line" | sed -E 's/^- base: ([0-9a-f]{40}).*/\1/')"
  head_sha="$(printf '%s\n' "$head_line" | sed -E 's/^- head: ([0-9a-f]{40}).*/\1/')"
  base_exit="$(printf '%s\n' "$base_line" | sed -E 's/.* exit=([0-9]+) result=.*/\1/')"
  head_exit="$(printf '%s\n' "$head_line" | sed -E 's/.* exit=([0-9]+) result=.*/\1/')"
  base_result="$(printf '%s\n' "$base_line" | sed -E 's/.* result=([^ ]+) log=.*/\1/')"
  head_result="$(printf '%s\n' "$head_line" | sed -E 's/.* result=([^ ]+) log=.*/\1/')"
  # A check can cover multiple paths, and an AMEND row supersedes the earlier
  # row for its exact (path, check-id) pair. Resolve the effective pair rows
  # first, then select the highest sequence so an amended checkpoint's base
  # SHA—not the historical first row—binds the replay evidence.
  manifest_base="$(awk -F '\t' -v want="$id" '
    NR > 1 && $6 == want {
      pair = length($3) ":" $3 ":" $6
      if (!(pair in latest_seq) || ($1 + 0) > latest_seq[pair]) {
        latest_seq[pair] = $1 + 0
        latest_base[pair] = $9
      }
    }
    END {
      for (pair in latest_seq) {
        if (!found || latest_seq[pair] > max_seq) {
          found = 1
          max_seq = latest_seq[pair]
          selected = latest_base[pair]
        }
      }
      if (found) print selected
    }
  ' "$manifest")"
  [ "$base_sha" = "$manifest_base" ] || rule_bad "base-identity-$id" "base SHA does not match checkpoint manifest"
  [ "$head_sha" = "$(git rev-parse HEAD)" ] || rule_bad "head-identity-$id" "head SHA does not match current HEAD"
  case "$class" in
    DISCRIMINATING) expected_base=RED; expected_head=GREEN; ;;
    PRESERVING) expected_base=GREEN; expected_head=GREEN; ;;
    NEW-SURFACE) expected_base=ERROR; expected_head=GREEN; ;;
    *) rule_bad "class-$id" "invalid executable class"; return ;;
  esac
  [ "$base_result" = "$expected_base" ] || rule_bad "base-result-$id" "expected $expected_base, recorded $base_result"
  [ "$head_result" = "$expected_head" ] || rule_bad "head-result-$id" "expected $expected_head, recorded $head_result"
  [ "$head_exit" -eq 0 ] || rule_bad "head-exit-$id" "post-fix replay must exit 0"
  case "$class" in
    DISCRIMINATING|NEW-SURFACE)
      [ "$base_exit" -ne 0 ] || rule_bad "base-exit-$id" "pre-fix replay must be nonzero"
      if ! trace_path_safe "$trace/repro/$id.base.log" file || ! grep -Eq -- "$expect" "$trace/repro/$id.base.log"; then
        rule_bad "base-log-$id" "pre-fix replay log is missing or does not match expect"
      fi
      ;;
    PRESERVING) [ "$base_exit" -eq 0 ] || rule_bad "base-exit-$id" "preserving replay must be green at base" ;;
  esac
  trace_path_safe "$trace/repro/$id.base.log" file || rule_bad "base-log-$id" "missing or unsafe replay log"
  trace_path_safe "$trace/repro/$id.head.log" file || rule_bad "head-log-$id" "missing or unsafe replay log"
  rule_ok "check-evidence-$id"
}
phase4() {
  local file="$trace/08-test-results.md" id manifest check_block_count deferred_clean_count rows row class
  check_headings "$file" '## Regression Test' '## Acceptance check results' '## Quality Checks' '## Deferred-Work Scan' '## Verification Reasoning' '## Checkpoint verification'
  manifest="$trace/repro/checkpoint.manifest"
  trace_path_safe "$trace/02-reproduction.md" file || { rule_bad acceptance-source "missing or unsafe reproduction artifact"; return; }
  trace_path_safe "$trace/repro" dir || { rule_bad recurrence-manifest "missing or unsafe repro directory"; return; }
  trace_path_safe "$manifest" file || { rule_bad recurrence-manifest "missing or unsafe checkpoint manifest"; return; }
  rows="$(acceptance_table_rows "$trace/02-reproduction.md")" || { rule_bad acceptance-table "missing or malformed acceptance table"; return; }
  while IFS= read -r id; do
    [ -z "$id" ] || {
      check_block_count="$(normalize_terminal_cr "$file" | awk -v marker="### Check $id" '$0 == marker || index($0, marker " (") == 1 { count++ } END { print count + 0 }')"
      [ "${check_block_count:-0}" -eq 1 ] && rule_ok "check-block-$id" || rule_bad "check-block-$id" "must appear exactly once"
      [ "${check_block_count:-0}" -eq 1 ] && phase4_check_evidence "$file" "$id"
    }
  done < <(executable_ids)
  while IFS= read -r id; do
    [ -z "$id" ] || { manifest_has_check_id "$manifest" "$id" && rule_ok "manifest-check-$id" || rule_bad "manifest-check-$id" "executable acceptance check is missing from the effective manifest"; }
  done < <(executable_ids)
  if bash "$script_dir/repro-check.sh" verify-semantics --slug "$slug" --trace-dir "$trace" >/dev/null 2>&1; then
    rule_ok acceptance-manifest-semantics
  else
    rule_bad acceptance-manifest-semantics "acceptance table semantics do not match checkpoint manifest"
  fi
  if bash "$script_dir/repro-check.sh" verify-checkpoint --slug "$slug" --trace-dir "$trace" >/dev/null 2>&1; then rule_ok checkpoint-verification; else rule_bad checkpoint-verification "verify-checkpoint failed"; fi
  deferred_clean_count="$(normalize_terminal_cr "$file" | grep -A100 '^## Deferred-Work Scan$' | grep -c '^scan-deferred: clean' || true)"
  [ "${deferred_clean_count:-0}" -gt 0 ] && rule_ok deferred-work-scan || rule_bad deferred-work-scan "clean result missing"
}

phase42() {
  local file="$trace/08a-recurrence-sweep.md" hits rows
  trace_path_safe "$file" file || { rule_bad recurrence-sweep "missing"; return; }
  if normalize_terminal_cr "$file" | grep -Eq '^no-defect-class: true$'; then
    if recurrence_justification_ok "$file"; then rule_ok recurrence-sweep; else rule_bad recurrence-sweep "fast-path Justification must have non-placeholder text"; fi
    return
  fi
  check_headings "$file" '## Defect Class' '## Predicates and Results' '## Dispositions' '## Guardrail'
  hits="$(normalize_terminal_cr "$file" | grep -E '^- Predicate.*hits: [0-9]+' | sed -E 's/.*hits: ([0-9]+).*/\1/' | awk '{s += $1} END {print s + 0}')"
  normalize_terminal_cr "$file" | grep -Eq '^- Predicate.*hits: [0-9]+' && rule_ok recurrence-predicates || rule_bad recurrence-predicates "missing hit counts"
  rows="$(normalize_terminal_cr "$file" | awk '/^## Dispositions$/{in_table=1; next} /^## /{in_table=0} in_table && /^\|/ && $0 !~ /^\|[ -]*\|/ {n++} END {print n-1}')"
  [ "$hits" -eq "$rows" ] && rule_ok recurrence-dispositions || rule_bad recurrence-dispositions "rows ($rows) do not equal hits ($hits)"
  normalize_terminal_cr "$file" | grep -A100 '^## Guardrail$' | tr '\n' ' ' | grep -Eq '### Check .*RED.*GREEN' && rule_ok recurrence-guardrail || rule_bad recurrence-guardrail "missing RED then GREEN check"
}

phase45() {
  clean_tree
  local file="$trace/08b-implementation-review.md" head tid
  check_headings "$file" '## Reviewed SHA / diff hash' '## Verdict' '## Independently re-run' '## Check integrity' '## Deferred / Scoped-Out / Unwired'
  trace_path_safe "$file" file || return
  artifact_verdict_approved "$file" && rule_ok artifact-verdict-implementation-review || rule_bad artifact-verdict-implementation-review "must contain APPROVE under ## Verdict"
  head="$(git rev-parse HEAD)"; tid="$(tree_id)"
  state_gate implementation-review APPROVE "$head" "$tid"
  artifact_identity_matches_gate "$file" implementation-review "$head" "$tid"
}
phase46() {
  local ac file="$trace/09-final-critic.md" head tid evidence_count
  clean_tree
  check_headings "$file" '## Reviewed SHA / diff hash' '## Verdict' '## Review Freshness' '## Deferred / Scoped-Out / Unwired' '## Acceptance criteria evidence'
  trace_path_safe "$file" file || return
  trace_path_safe "$trace/01-issue-summary.md" file || { rule_bad acceptance-source "missing or unsafe issue summary"; return; }
  artifact_verdict_approved "$file" && rule_ok artifact-verdict-final-critic || rule_bad artifact-verdict-final-critic "must contain APPROVE under ## Verdict"
  head="$(git rev-parse HEAD)"; tid="$(tree_id)"
  state_gate final-critic APPROVE "$head" "$tid"
  artifact_identity_matches_gate "$file" final-critic "$head" "$tid"
  while IFS= read -r ac; do
    evidence_count="$(normalize_terminal_cr "$file" | grep -A100 '^## Acceptance criteria evidence$' | grep -c "$ac" || true)"
    [ "${evidence_count:-0}" -gt 0 ] && rule_ok "final-$ac" || rule_bad "final-$ac" "missing evidence"
  done < <(acceptance_ids)
}
phase5() {
  if is_already_fixed; then rule_ok obe-subset; return; fi
  local file="$trace/10-pr-body.md" merge_value pr_head_line pr_head_sha
  check_headings "$file" '## Acceptance Criteria -> Evidence' '## Waivers (or none)'
  trace_path_safe "$file" file || return
  pr_head_line="$(awk '{ sub(/\r$/, "", $0); if ($0 ~ /^PR head: [0-9a-f]{40}$/) { print; exit } }' "$file" 2>/dev/null || true)"
  if [ -z "$pr_head_line" ]; then
    rule_bad pr-head "missing PR head: <40-hex> line"
  else
    pr_head_sha="${pr_head_line#PR head: }"
    if [ "$pr_head_sha" = "$(git rev-parse HEAD)" ]; then rule_ok pr-head; else rule_bad pr-head "does not match HEAD"; fi
  fi
  merge_value="$(state_value merge)"
  case "$merge_value" in
    AWAITING_USER_APPROVAL|MERGED) rule_ok merge-state ;;
    APPROVED:*) is_hex "${merge_value#APPROVED:}" && rule_ok merge-state || rule_bad merge-state "APPROVED: must be followed by a 40-hex sha" ;;
    *) rule_bad merge-state "not ready" ;;
  esac
}
merge_check() {
  local file="$trace/10b-merge-approval.md" pr final
  check_headings "$file" '## User approval (verbatim)' '## PR head SHA' '## Final critic reviewed-commit'
  trace_path_safe "$file" file || return
  pr="$(normalize_terminal_cr "$file" | grep -A3 '^## PR head SHA$' | grep -Eo '[0-9a-f]{40}' | head -n1 || true)"
  final="$(normalize_terminal_cr "$file" | grep -A3 '^## Final critic reviewed-commit$' | grep -Eo '[0-9a-f]{40}' | head -n1 || true)"
  is_hex "$pr" && [ "$pr" = "$final" ] && rule_ok merge-sha-binding || rule_bad merge-sha-binding "PR and final critic SHA differ"
  state_gate merge-approval RECORDED "" ""
  echo 'NOTE: human-enforced gate; this validator checks presence and binding only'
}

command="${1:-}"; shift || true
case "$command" in
  tree-id) [ "$#" -eq 0 ] || usage; tree_id; exit $? ;;
  handshake) [ "$#" -eq 0 ] || usage; handshake; exit 0 ;;
  phase) phase="${1:-}"; shift || true; case "$phase" in 0|1|2|2.5|3|4|4.2|4.5|4.6|5) ;; *) usage;; esac ;;
  merge) phase="merge" ;;
  *) usage ;;
esac
slug=""; trace=""
while [ "$#" -gt 0 ]; do
  case "$1" in --slug) [ "$#" -ge 2 ] || usage; slug="$2"; shift 2;; --trace-dir) [ "$#" -ge 2 ] || usage; trace="$2"; shift 2;; *) usage;; esac
done
valid_slug "$slug" || { echo "trace-check: invalid slug" >&2; exit 2; }
[ -n "$trace" ] || trace="$root/.agents/issue-traces/$slug"
trace="$(to_shell_path "$trace")"
validate_trace_dir "$trace"
# Use the same canonical spelling that validate_trace_dir checked for all
# subsequent artifact reads. Windows may accept an existing 8.3 alias for the
# explicit directory while pwd -P exposes the long spelling; retaining the
# alias here would make trace_path_safe compare unlike path strings. Preserve
# the established exit-1 result for a valid-but-absent default trace directory.
if [ -d "$trace" ]; then
  trace="$(cd "$trace" 2>/dev/null && pwd -P)" || {
    echo "FAIL state: could not resolve canonical trace root $trace" >&2
    exit 2
  }
fi
state="$trace/state.md"
if [ ! -d "$trace" ]; then
  echo "FAIL state: missing or unsafe trace directory $trace"
  exit 1
fi
trace_root_real="$(cd "$trace" 2>/dev/null && pwd -P)" || {
  echo "FAIL state: could not resolve canonical trace root $trace" >&2
  exit 2
}
case "$trace_root_real/" in
  "$root_real/.agents/issue-traces/"*) ;;
  *) echo "FAIL state: canonical trace root escapes .agents/issue-traces" >&2; exit 2;;
esac
if ! trace_path_safe "$trace" dir; then
  echo "FAIL state: missing or unsafe trace directory $trace"
  exit 1
fi
if ! trace_path_safe "$state" file; then
  echo "FAIL state: missing $state"
  exit 1
fi
protocol_line="$(state_lines | grep -c '^protocol: ' || true)"
protocol_value="$(state_value protocol)"
if [ "${protocol_line:-0}" -eq 0 ]; then
  # No protocol line at all: legacy v2 ledger unless a v3-only key is present,
  # in which case this is a v3 ledger that had its protocol line stripped.
  v3_marker_lines="$(state_lines | grep -Ec '^(phase0-tree-id|checkpoint-tree-id|handshake): ' || true)"
  if [ "${v3_marker_lines:-0}" -gt 0 ]; then
    echo "FAIL state-protocol: missing (v3 ledger without protocol line)"
    exit 1
  fi
  legacy=1
  echo "WARN protocol: legacy trace (protocol missing), all failures downgraded to WARN"
elif [ "$protocol_value" != "3.0.0" ]; then
  echo "FAIL state-protocol: unsupported $protocol_value"
  exit 1
fi

if [ "$phase" = merge ]; then merge_check
else
  if is_already_fixed && [ "$phase" != 0 ] && [ "$phase" != 1 ] && [ "$phase" != 2 ]; then
    rule_ok obe-subset
  else
    case "$phase" in
      0) phase0;; 1) phase1;; 2) phase2;; 2.5) phase25;; 3) phase3;; 4) phase4;; 4.2) phase42;; 4.5) phase45;; 4.6) phase46;; 5) phase5;;
    esac
  fi
fi
[ "$failed" -eq 0 ] || exit 1
exit 0
