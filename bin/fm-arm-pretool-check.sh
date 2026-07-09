#!/usr/bin/env bash
# PreToolUse seatbelt against the firstmate watcher-arm anti-pattern.
#
# A firstmate PRIMARY must arm the watcher (bin/fm-watch-arm.sh) or run a
# Codex checkpoint (bin/fm-watch-checkpoint.sh) as a STANDALONE, VERIFIED
# harness call. On 2026-07-09 a Grok primary instead armed with shapes like
# `bin/fm-watch-arm.sh &`, `bin/fm-watch-arm.sh 2>&1 | head -2 &`, and the arm
# glued after another command with `&`. Each of those backgrounds the arm with
# a plain shell `&` (or pipes/bundles it) instead of using the harness's own
# tracked background mechanism, so the forked child is reaped the instant the
# tool call ends - leaving NO watcher running and supervision blind. See
# bin/fm-watch-arm.sh's own header for the incident this already guards
# against structurally; this script adds a pre-execution seatbelt so a
# harness that supports PreToolUse-style hooks can refuse the command before
# it ever runs.
#
# THIS IS A SEATBELT FOR KNOWN-BAD COMMAND SHAPES, NOT A POST-ARM LIVENESS
# GUARANTEE. It only inspects the text of a shell command about to run and
# denies a handful of specific anti-patterns (background operator, truncating
# pipe, stdio redirection, command substitution, bundling with other work,
# broad pkill). It cannot prove the watcher actually started and stayed
# healthy afterward - that is bin/fm-guard.sh and bin/fm-turnend-guard.sh's
# job, which run after the fact from the beacon and lock. A command this script
# allows can still fail to arm the watcher for unrelated reasons. See
# docs/arm-pretool-check.md for the full contract and the per-harness wiring
# audit.
#
# Usage:
#   <PreToolUse JSON on stdin> | bin/fm-arm-pretool-check.sh
#   bin/fm-arm-pretool-check.sh --command '<cmd>' [--background true|false]
#
# Stdin mode reads a harness PreToolUse-style payload and extracts the shell
# command from, in order: .toolInput.command (Grok), .tool_input.command
# (Claude, Codex). .toolInput.background / .tool_input.background is read for
# context only - it names the harness's OWN tracked background mechanism
# (e.g. Grok's run_terminal_command background:true tool parameter), which is
# the CORRECT way to background the arm, and is never itself a deny signal.
# The only backgrounding this script objects to is a shell-level operator
# inside the command text (&, nohup, disown), because that bypasses the
# harness's tracking entirely.
#
# CLI mode (--command) is for adapters that already extracted the command
# themselves (OpenCode/Pi plugin JSON differs in shape) and for tests; it
# never touches jq.
#
# Exit/output contract:
#   ALLOW - exit 0. No stdout for an irrelevant command (fast pass-through).
#   DENY  - exit 2, plus BOTH of:
#             stdout: {"decision":"deny","reason":"..."} (Grok's PreToolUse
#               contract; verified 2026-07-09 against grok 0.2.93 - exit 2
#               alone is not honored without this).
#             stderr: {"hookSpecificOutput":{"hookEventName":"PreToolUse",
#               "permissionDecision":"deny"},"systemMessage":"..."} (Claude
#               Code's PreToolUse contract; verified 2026-07-09 - plain-text
#               stderr + exit 2, which is sufficient for Claude's Stop hook,
#               is NOT sufficient here and silently lets the tool run).
#           Codex reads plain exit 2 and shows stderr verbatim (verified
#           2026-07-09 against codex-cli 0.143.0), so the JSON on stderr is
#           merely displayed as text there - still a clean deny.
#   Fail-open - unparseable/empty JSON in stdin mode, or missing jq in stdin
#   mode, always exits 0. A hook must never crash-deny everything.
#
# --claude: Claude Code only honors a PreToolUse deny when stdout is EMPTY
# and the hookSpecificOutput JSON is on stderr alone (verified 2026-07-09
# against Claude Code 2.1.204: ANY content on stdout - even Grok's own
# {"decision":...} JSON, even a combined object carrying both schemas -
# makes Claude silently allow the tool instead of falling back to stderr).
# Pass --claude from the Claude adapter to suppress the stdout deny JSON;
# every other caller (Grok, Codex, tests, CLI use) keeps the default dual
# output.
set -u

CMD=""
CMD_SET=0
BACKGROUND=""
CLAUDE_MODE=0

usage() {
  cat <<'EOF'
Usage: fm-arm-pretool-check.sh [--command <cmd>] [--background true|false] [--claude]

With no --command, reads a PreToolUse-style JSON payload on stdin (Grok
toolInput.command, or Claude/Codex tool_input.command).
Exits 0 to allow, 2 to deny (deny reason on stderr, deny decision JSON on
stdout unless --claude). Fails open (exit 0) on unparseable/empty input or
missing jq.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --command)
      [ "$#" -gt 1 ] || { echo "error: --command requires a value" >&2; exit 2; }
      CMD=$2
      CMD_SET=1
      shift 2
      ;;
    --command=*)
      CMD=${1#--command=}
      CMD_SET=1
      shift
      ;;
    --background)
      [ "$#" -gt 1 ] || { echo "error: --background requires a value" >&2; exit 2; }
      BACKGROUND=$2
      shift 2
      ;;
    --background=*)
      BACKGROUND=${1#--background=}
      shift
      ;;
    --claude)
      CLAUDE_MODE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

# --- input acquisition -------------------------------------------------------

if [ "$CMD_SET" -eq 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  command -v jq >/dev/null 2>&1 || exit 0
  CMD=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.command // .tool_input.command // empty)' 2>/dev/null) || exit 0
  [ -n "$CMD" ] || exit 0
  # Read for context/logging parity with --background only; never a gating
  # signal (see the usage header: harness-native background:true is correct
  # usage, only a shell-level '&' is the anti-pattern).
  # shellcheck disable=SC2034
  BACKGROUND=$(printf '%s' "$PAYLOAD" | jq -r '(.toolInput.background // .tool_input.background // false)' 2>/dev/null) || BACKGROUND=false
fi

[ -n "$CMD" ] || exit 0

# --- pattern detection --------------------------------------------------------

is_relevant() {
  printf '%s' "$1" | grep -Eq \
    -e 'fm-watch-arm(\.sh)?\b' \
    -e 'fm-watch-checkpoint\.sh\b' \
    -e 'fm-watch\.sh\b' \
    -e '\bpkill\b[^|;&]*fm-watch'
}

is_pkill_watch() {
  printf '%s' "$1" | grep -Eq '\bpkill\b[^|;&]*fm-watch'
}

# Bare shell `&` (not `&&` or redirection), or nohup/disown anywhere in an
# already-relevant command.
has_bare_background_operator() {
  local cmd=$1
  local i len ch prev next in_single=0 in_double=0 escaped=0
  len=${#cmd}
  for ((i = 0; i < len; i++)); do
    ch=${cmd:i:1}
    if [ "$escaped" -eq 1 ]; then
      escaped=0
      continue
    fi
    if [ "$in_single" -eq 0 ] && [ "$ch" = "\\" ]; then
      escaped=1
      continue
    fi
    if [ "$in_double" -eq 0 ] && [ "$ch" = "'" ]; then
      if [ "$in_single" -eq 0 ]; then in_single=1; else in_single=0; fi
      continue
    fi
    if [ "$in_single" -eq 0 ] && [ "$ch" = '"' ]; then
      if [ "$in_double" -eq 0 ]; then in_double=1; else in_double=0; fi
      continue
    fi
    if [ "$in_single" -ne 0 ] || [ "$in_double" -ne 0 ]; then
      continue
    fi
    [ "$ch" = "&" ] || continue

    prev=""
    next=""
    [ "$i" -gt 0 ] && prev=${cmd:i-1:1}
    [ "$((i + 1))" -lt "$len" ] && next=${cmd:i+1:1}
    [ "$next" = "&" ] && { i=$((i + 1)); continue; }
    [ "$prev" = ">" ] && continue
    [ "$next" = ">" ] && continue
    return 0
  done
  return 1
}

has_nested_shell_evaluator() {
  local cmd=$1
  printf '%s' "$cmd" | grep -Eq \
    -e '(^|[[:space:];|&])([^[:space:];|&]*/)?(bash|sh|zsh)([[:space:]][^;|&]*)?[[:space:]]-[^[:space:]]*c([[:space:]]|$)' \
    -e '(^|[[:space:];|&])eval([[:space:]]|$)'
}

nested_shell_projection() {
  printf '%s' "$1" | tr -d "'\""
}

has_nested_shell_background_operator() {
  local cmd=$1 projected
  has_nested_shell_evaluator "$cmd" || return 1
  projected=$(nested_shell_projection "$cmd")
  has_bare_background_operator "$projected"
}

has_shell_list_operator() {
  local cmd=$1
  printf '%s' "$cmd" | grep -Eq '&&|\|\|' && return 0
  has_bare_background_operator "$cmd" && return 0
  return 1
}

has_command_or_process_substitution() {
  local cmd=$1
  local i len ch next in_single=0 in_double=0 escaped=0
  len=${#cmd}
  for ((i = 0; i < len; i++)); do
    ch=${cmd:i:1}
    if [ "$escaped" -eq 1 ]; then
      escaped=0
      continue
    fi
    if [ "$in_single" -eq 0 ] && [ "$ch" = "\\" ]; then
      escaped=1
      continue
    fi
    if [ "$in_double" -eq 0 ] && [ "$ch" = "'" ]; then
      if [ "$in_single" -eq 0 ]; then in_single=1; else in_single=0; fi
      continue
    fi
    if [ "$in_single" -eq 0 ] && [ "$ch" = '"' ]; then
      if [ "$in_double" -eq 0 ]; then in_double=1; else in_double=0; fi
      continue
    fi
    [ "$in_single" -eq 0 ] || continue

    next=""
    [ "$((i + 1))" -lt "$len" ] && next=${cmd:i+1:1}
    [ "$ch" = "$" ] && [ "$next" = "(" ] && return 0
    [ "$ch" = '`' ] && return 0
    { [ "$ch" = "<" ] || [ "$ch" = ">" ]; } && [ "$next" = "(" ] && return 0
  done
  return 1
}

has_shell_redirection() {
  local cmd=$1
  local i len ch in_single=0 in_double=0 escaped=0
  len=${#cmd}
  for ((i = 0; i < len; i++)); do
    ch=${cmd:i:1}
    if [ "$escaped" -eq 1 ]; then
      escaped=0
      continue
    fi
    if [ "$in_single" -eq 0 ] && [ "$ch" = "\\" ]; then
      escaped=1
      continue
    fi
    if [ "$in_double" -eq 0 ] && [ "$ch" = "'" ]; then
      if [ "$in_single" -eq 0 ]; then in_single=1; else in_single=0; fi
      continue
    fi
    if [ "$in_single" -eq 0 ] && [ "$ch" = '"' ]; then
      if [ "$in_double" -eq 0 ]; then in_double=1; else in_double=0; fi
      continue
    fi
    if [ "$in_single" -ne 0 ] || [ "$in_double" -ne 0 ]; then
      continue
    fi
    { [ "$ch" = "<" ] || [ "$ch" = ">" ]; } && return 0
  done
  return 1
}

is_backgrounded() {
  local cmd=$1
  has_bare_background_operator "$cmd" && return 0
  has_nested_shell_background_operator "$cmd" && return 0
  printf '%s' "$cmd" | grep -Eq '\b(nohup|disown)\b' && return 0
  return 1
}

has_nested_shell_redirection() {
  local cmd=$1 projected
  has_nested_shell_evaluator "$cmd" || return 1
  projected=$(nested_shell_projection "$cmd")
  has_shell_redirection "$projected"
}

has_nested_command_or_process_substitution() {
  local cmd=$1 projected
  has_nested_shell_evaluator "$cmd" || return 1
  projected=$(nested_shell_projection "$cmd")
  has_command_or_process_substitution "$projected"
}

# Piped into a tool that can tear down attach-and-wait early.
is_piped_truncated() {
  printf '%s' "$1" | grep -Eq '\|[[:space:]]*(head|tail|timeout)\b|\|[[:space:]]*sed[[:space:]]+-n\b'
}

# Count top-level statements, treating ';', '&&', '||', and newlines as
# separators. Only used as a fallback signal once the blessed-shape check
# below has already ruled the command out, so it never needs to special-case
# the guarded x-mode source clause.
statement_count() {
  local cmd=$1 normalized
  normalized=$(printf '%s' "$cmd" | sed -E 's/&&/\n/g; s/\|\|/\n/g; s/;/\n/g')
  printf '%s\n' "$normalized" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' | grep -c '[^[:space:]]'
}

# The blessed shape: optional cd/export/guarded-x-mode-source leading
# statements, then a sole final exec of fm-watch-arm.sh (optional --restart)
# or a sole fm-watch-checkpoint.sh invocation. No pipes, background operator,
# redirection, or command/process substitution anywhere.
is_blessed_shape() {
  local cmd=$1
  printf '%s' "$cmd" | grep -Eq '\|' && return 1
  is_backgrounded "$cmd" && return 1
  has_shell_redirection "$cmd" && return 1
  has_command_or_process_substitution "$cmd" && return 1

  local normalized line trimmed
  normalized=$(printf '%s' "$cmd" | tr ';' '\n')
  local -a stmts=()
  while IFS= read -r line; do
    trimmed=$(printf '%s' "$line" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')
    [ -n "$trimmed" ] && stmts+=("$trimmed")
  done <<EOF
$normalized
EOF

  local n=${#stmts[@]}
  [ "$n" -ge 1 ] || return 1

  local last=${stmts[$((n - 1))]}
  has_shell_list_operator "$last" && return 1
  local last_ok=1
  printf '%s' "$last" | grep -Eq '^(exec[[:space:]]+)?(\./)?bin/fm-watch-arm\.sh([[:space:]]+--restart)?[[:space:]]*$' && last_ok=0
  if [ "$last_ok" -ne 0 ]; then
    printf '%s' "$last" | grep -Eq '^(\./)?bin/fm-watch-checkpoint\.sh([[:space:]]+[^[:space:]]+)*[[:space:]]*$' && last_ok=0
  fi
  [ "$last_ok" -eq 0 ] || return 1

  local i stmt
  for ((i = 0; i < n - 1; i++)); do
    stmt=${stmts[$i]}
    printf '%s' "$stmt" | grep -Eq '^\[[[:space:]]+-f[[:space:]]+config/x-mode\.env[[:space:]]+\][[:space:]]+&&[[:space:]]+(\.|source)[[:space:]]+config/x-mode\.env$' && continue
    has_shell_list_operator "$stmt" && return 1
    printf '%s' "$stmt" | grep -Eq '^cd[[:space:]]+[^[:space:]]+$' && continue
    printf '%s' "$stmt" | grep -Eq '^export[[:space:]]+[A-Za-z_][A-Za-z0-9_]*=.*$' && continue
    printf '%s' "$stmt" | grep -Eq '^(\.|source)[[:space:]]+config/x-mode\.env$' && continue
    return 1
  done
  return 0
}

json_escape() {
  # Minimal JSON string escaper, dependency-free so CLI mode never needs jq.
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | tr '\n' ' '
}

# --- decision -----------------------------------------------------------------

DENY=0
REASON=""

if is_pkill_watch "$CMD"; then
  DENY=1
  REASON="broad pkill against the firstmate watcher is forbidden: it matches every firstmate home's watcher (secondmate homes run the same script) and can kill a sibling's supervision. Use bin/fm-watch-arm.sh --restart for a home-scoped restart, never pkill -f fm-watch."
elif is_relevant "$CMD"; then
  if is_blessed_shape "$CMD"; then
    DENY=0
  elif is_backgrounded "$CMD"; then
    DENY=1
    REASON="backgrounds the watcher arm/checkpoint with a shell '&' (or nohup/disown). That child is reaped the instant this tool call ends, leaving no watcher running - run bin/fm-watch-arm.sh as the harness's own standalone background tool call instead, never fired with a trailing '&'."
  elif is_piped_truncated "$CMD"; then
    DENY=1
    REASON="pipes the watcher arm/checkpoint through head/tail/timeout/sed -n, which can tear down attach-and-wait before the watcher confirms it started."
  elif has_shell_redirection "$CMD"; then
    DENY=1
    REASON="redirects the watcher arm/checkpoint stdio with shell redirection, which can hide the status and wake lines the primary relies on."
  elif has_nested_shell_redirection "$CMD"; then
    DENY=1
    REASON="redirects the watcher arm/checkpoint stdio inside a nested shell payload, which can hide the status and wake lines the primary relies on."
  elif has_command_or_process_substitution "$CMD"; then
    DENY=1
    REASON="runs command or process substitution inside a watcher arm/checkpoint command. Run the watcher arm/checkpoint as its own literal standalone command."
  elif has_nested_command_or_process_substitution "$CMD"; then
    DENY=1
    REASON="runs command or process substitution inside a nested shell watcher arm/checkpoint payload. Run the watcher arm/checkpoint as its own literal standalone command."
  elif [ "$(statement_count "$CMD")" -gt 1 ]; then
    DENY=1
    REASON="bundles the watcher arm/checkpoint with other work in a multi-statement command. Run it as its own standalone command, optionally preceded only by cd/export/source config/x-mode.env."
  fi
fi

if [ "$DENY" -eq 1 ]; then
  ESCAPED=$(json_escape "$REASON")
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny"},"systemMessage":"%s"}\n' "$ESCAPED" >&2
  # Claude Code only honors the stderr deny when stdout is empty; see the
  # --claude usage note above. Every other consumer needs the Grok-shaped
  # decision JSON on stdout.
  [ "$CLAUDE_MODE" -eq 1 ] || printf '{"decision":"deny","reason":"%s"}\n' "$ESCAPED"
  exit 2
fi

exit 0
