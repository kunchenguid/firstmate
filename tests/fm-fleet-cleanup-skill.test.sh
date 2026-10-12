#!/usr/bin/env bash
# Portable structural validation for the fleet-cleanup skill artifact.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# Read through the loader-facing .claude/skills symlink rather than the tracked
# directory, so this also proves the skill is reachable the way a harness loads it.
SKILL="$ROOT/.claude/skills/fleet-cleanup/SKILL.md"
TMP_ROOT=$(fm_test_tmproot fm-fleet-cleanup-skill)
FRONTMATTER="$TMP_ROOT/frontmatter.yaml"

[ -r "$SKILL" ] || fail "fleet-cleanup skill is not readable at .claude/skills/fleet-cleanup/SKILL.md"

awk '
  NR == 1 && $0 != "---" { exit 1 }
  NR == 1 { next }
  /^---$/ { closed = 1; exit }
  { print }
  END { if (!closed) exit 1 }
' "$SKILL" > "$FRONTMATTER" || fail "fleet-cleanup skill has no closed YAML frontmatter block"

# Flatten the frontmatter into normalized `path=value` pairs before asserting, so
# nesting is actually proven. Independent greps for `metadata:` and `internal: true`
# both pass on a file whose metadata.internal is false, and pinning indentation
# fails a semantically identical reflow. An indent keyed stack is what keeps a
# deeper `metadata.extra.internal` from collapsing onto `metadata.internal`.
# POSIX awk only (CI runs mawk), avoiding a YAML dependency neither CI nor
# tests/lib.sh already carries.
MODEL="$TMP_ROOT/frontmatter.model"
awk '
  function trim(v) {
    sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
    if (v ~ /^".*"$/ || v ~ /^'"'"'.*'"'"'$/) v = substr(v, 2, length(v) - 2)
    return v
  }
  function path(k,   i, p) { p = ""; for (i = 1; i <= depth; i++) p = p stack_key[i] "."; return p k }
  function emit(p, v) {
    if (!(p in cell)) order[++n_order] = p
    cell[p] = v
  }
  {
    if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) next
    pos = match($0, /[^[:space:]]/); if (pos == 0) next
    indent = pos - 1
    # Inside a block scalar the body is prose, never child keys. Record the first
    # body line as the value so an empty block scalar is distinguishable.
    if (in_scalar) {
      if (indent > scalar_indent) {
        if (!scalar_emitted) { emit(scalar_path, trim($0)); scalar_emitted = 1 }
        next
      }
      in_scalar = 0
    }
    ci = index($0, ":"); if (ci == 0) next
    key = trim(substr($0, pos, ci - pos))
    val = trim(substr($0, ci + 1))
    while (depth > 0 && stack_indent[depth] >= indent) depth--
    full = path(key)
    if (val ~ /^[>|]/) {
      in_scalar = 1; scalar_indent = indent; scalar_path = full; scalar_emitted = 0
      next
    }
    if (val == "") { depth++; stack_indent[depth] = indent; stack_key[depth] = key; next }
    if (val ~ /^\{.*\}$/) {
      inner = substr(val, 2, length(val) - 2)
      n = split(inner, pairs, ",")
      for (i = 1; i <= n; i++) {
        pc = index(pairs[i], ":")
        if (pc > 0) emit(full "." trim(substr(pairs[i], 1, pc - 1)), trim(substr(pairs[i], pc + 1)))
      }
      next
    }
    emit(full, val)
  }
  END {
    for (i = 1; i <= n_order; i++) print order[i] "=" cell[order[i]]
  }
' "$FRONTMATTER" > "$MODEL"

grep -qx 'name=fleet-cleanup' "$MODEL" \
  || fail "fleet-cleanup skill frontmatter name must match its directory"
grep -qx 'user-invocable=false' "$MODEL" \
  || fail "fleet-cleanup skill must declare itself agent-only"
grep -qx 'metadata.internal=true' "$MODEL" \
  || fail "fleet-cleanup skill must set metadata.internal=true so installers do not surface it"
# Require description TEXT, not just the key: a bare `description:` leaves the
# loader with no trigger at all, which is the contract this guards.
grep -q '^description=..*' "$MODEL" \
  || fail "fleet-cleanup skill frontmatter must carry a non-empty description"

# A skill nothing loads is dead weight, so the declared trigger must be registered.
# The complete trigger list lives in the agent-skill-trigger-index skill's prose and
# nothing in bin/ consumes it (bin/fm-test-run.sh keys on the SKILL.md path, not the
# trigger), so parse that prose: each top-level `- `skill` - ` bullet plus its
# continuation lines becomes one `skill=trigger` row, and fleet-cleanup must have a
# row whose trigger text is non-empty.
INDEX_MODEL="$TMP_ROOT/trigger-index.model"
# shellcheck disable=SC2016 # Backticks are literal Markdown here, not a subshell.
awk '
  function flush() {
    if (cur == "") return
    sub(/^[[:space:]]+/, "", trig)
    sub(/[[:space:]]+$/, "", trig)
    print cur "=" trig
    cur = ""; trig = ""
  }
  /^- `[^`]+` -/ {
    flush()
    s = substr($0, 4)
    c = index(s, "`")
    if (c == 0) next
    cur = substr(s, 1, c - 1)
    rest = substr(s, c + 1)
    trig = substr(rest, 3)
    next
  }
  /^[[:space:]]*$/ { next }
  /^[[:space:]]/ {
    if (cur != "") trig = trig " " $0
    next
  }
  { flush() }
  END { flush() }
' "$ROOT/.agents/skills/agent-skill-trigger-index/SKILL.md" > "$INDEX_MODEL"
grep -q '^fleet-cleanup=..*' "$INDEX_MODEL" \
  || fail "fleet-cleanup skill has no non-empty trigger in the agent-only trigger index"

pass "fleet-cleanup skill is reachable, agent-only, installer-internal, and has a declared load trigger"
