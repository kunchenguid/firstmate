# shellcheck shell=bash
# Forbidden-model policy primitives.
# Usage: . bin/fm-model-policy-lib.sh
#
# A home whose operator must never spend on a particular model cannot rely on
# every dispatch profile being re-read by eye. config/model-denylist makes that
# an enforced local policy: this library owns the file format and the refusal
# decision, bin/fm-bootstrap.sh applies it when it validates configuration,
# bin/fm-spawn.sh applies it to the fully resolved profile before a worker is
# launched, and bin/fm-control.sh applies it before a relaunch stops the running
# agent. docs/configuration.md "Forbidden models" owns the operator contract.
#
# File format, one item per line:
#   - Text from the first "#" to end of line is a comment; blank lines are skipped.
#   - Every other line is a denied fragment: a model is refused when the
#     fragment appears anywhere in its lowercased text. Fragments rather than
#     exact ids, because one vendor model reaches Firstmate under several
#     spellings ("fable", "claude-fable-5", "anthropic/claude-fable-5").
#
# Two deliberate properties:
#   - An absent file means no policy at all, so a home that has not opted in
#     behaves exactly as before.
#   - A present-but-unusable file (symlink, directory, unreadable) is an error
#     that refuses, never a policy that quietly evaporates.
#
# Naming no model at all is refused, with no opt-out: the model would otherwise
# come from the harness's own account-level default, which the vendor controls
# and can change to the very model the operator forbade. A home that forbids a
# model names one everywhere; an exemption from this rule is the single thing
# that would restore the hole it closes.
#
# Vendor aliases ("best" and friends) resolve to a concrete model inside the
# harness, and that mapping changes without notice, so Firstmate cannot resolve
# one without asking the vendor and spending on the answer. An alias is denied
# only when the operator lists it, which is exactly why an unnamed model is
# refused.

FM_MODEL_POLICY_FILE="model-denylist"

# Set by the functions below; read by callers after a non-zero return.
FM_MODEL_POLICY_ERROR=""
# 1 once a usable file has been loaded, 0 when this home has no policy.
FM_MODEL_POLICY_ACTIVE=0
# Loaded denied fragments, one per line, lowercased and trimmed.
FM_MODEL_POLICY_ENTRIES=""

# fm_model_policy_load <config-dir>
# Loads the policy, or reports why a present file cannot be trusted.
fm_model_policy_load() {
  local config_dir=$1 path body line entry
  FM_MODEL_POLICY_ERROR=""
  FM_MODEL_POLICY_ACTIVE=0
  FM_MODEL_POLICY_ENTRIES=""
  path="$config_dir/$FM_MODEL_POLICY_FILE"
  if [ -L "$path" ]; then
    FM_MODEL_POLICY_ERROR="config/$FM_MODEL_POLICY_FILE is symlinked; a forbidden-model policy must be a plain file in this home"
    return 1
  fi
  [ -e "$path" ] || return 0
  if [ ! -f "$path" ]; then
    FM_MODEL_POLICY_ERROR="config/$FM_MODEL_POLICY_FILE is not a regular file"
    return 1
  fi
  # The stderr redirect comes first so bash's own "Permission denied" for an
  # unreadable input is suppressed too, and the reason reaches the caller as
  # FM_MODEL_POLICY_ERROR rather than as a stray line in a diagnostic report.
  body=$(tr '[:upper:]' '[:lower:]' 2>/dev/null < "$path") || {
    FM_MODEL_POLICY_ERROR="config/$FM_MODEL_POLICY_FILE could not be read"
    return 1
  }
  FM_MODEL_POLICY_ACTIVE=1
  while IFS= read -r line || [ -n "$line" ]; do
    entry=${line%%#*}
    entry=${entry#"${entry%%[![:space:]]*}"}
    entry=${entry%"${entry##*[![:space:]]}"}
    [ -n "$entry" ] || continue
    FM_MODEL_POLICY_ENTRIES="$FM_MODEL_POLICY_ENTRIES$entry
"
  done <<EOF
$body
EOF
  return 0
}

# fm_model_policy_denied_entry <text>
# Prints the first loaded fragment that appears in <text>, or nothing.
fm_model_policy_denied_entry() {
  local text entry
  text=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case "$text" in
    *"$entry"*)
      printf '%s\n' "$entry"
      return 0
      ;;
    esac
  done <<EOF
$FM_MODEL_POLICY_ENTRIES
EOF
  return 1
}

# fm_model_policy_unnamed <model>
# True when <model> names nothing: empty, whitespace, or the "default" sentinel
# fm-spawn records for a spawn that named no model.
fm_model_policy_unnamed() {
  local model=$1
  model=${model#"${model%%[![:space:]]*}"}
  model=${model%"${model##*[![:space:]]}"}
  [ -z "$model" ] || [ "$model" = default ]
}

# fm_model_policy_check <config-dir> <model> [<origin>]
# The model gate. Returns 1 with FM_MODEL_POLICY_ERROR set on refusal.
# <origin> names where the refused value came from, for a caller that resolved
# it from several places and would otherwise send the operator hunting through
# config files; a caller whose own prefix already says where omits it.
fm_model_policy_check() {
  local config_dir=$1 model=$2 origin=${3:-} hit
  fm_model_policy_load "$config_dir" || return 1
  [ "$FM_MODEL_POLICY_ACTIVE" = 1 ] || return 0
  if fm_model_policy_unnamed "$model"; then
    FM_MODEL_POLICY_ERROR="no model is named, so the harness would pick one from its own account default; config/$FM_MODEL_POLICY_FILE requires an explicit model"
    return 1
  fi
  if hit=$(fm_model_policy_denied_entry "$model"); then
    FM_MODEL_POLICY_ERROR="model '$model' matches '$hit' in config/$FM_MODEL_POLICY_FILE"
    [ -z "$origin" ] || FM_MODEL_POLICY_ERROR="$FM_MODEL_POLICY_ERROR (model came from $origin)"
    return 1
  fi
  return 0
}

# fm_model_policy_check_command <config-dir> <launch-command> <model>
# The gate for an operator-written raw launch command. Three rules, all of which
# must pass: no denied fragment anywhere in the command text, an explicitly
# named <model>, and a <model> the policy permits.
#
# The explicit model is required because this text is arbitrary shell that
# Firstmate cannot parse for the model it will run. Recognizing one inside it
# would be guesswork, and guessing wrong here launches the forbidden model, so
# an unrecognizable command refuses and says what to add instead.
fm_model_policy_check_command() {
  local config_dir=$1 command=$2 model=${3:-} hit
  fm_model_policy_load "$config_dir" || return 1
  [ "$FM_MODEL_POLICY_ACTIVE" = 1 ] || return 0
  if hit=$(fm_model_policy_denied_entry "$command"); then
    FM_MODEL_POLICY_ERROR="launch command contains '$hit', denied by config/$FM_MODEL_POLICY_FILE"
    return 1
  fi
  if fm_model_policy_unnamed "$model"; then
    FM_MODEL_POLICY_ERROR="a raw launch command cannot be parsed for the model it will run, so config/$FM_MODEL_POLICY_FILE requires an explicit --model naming it"
    return 1
  fi
  if hit=$(fm_model_policy_denied_entry "$model"); then
    FM_MODEL_POLICY_ERROR="model '$model' matches '$hit' in config/$FM_MODEL_POLICY_FILE (model came from the --model flag)"
    return 1
  fi
  return 0
}
