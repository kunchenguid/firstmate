#!/usr/bin/env bash
# Deterministic delegated-Pi profile support for fm-spawn.sh.
#
# A home opts in with config/pi-delegated-profile using exactly these keys:
#   pi_command=/absolute/path/to/pi
#   pi_version=0.81.1
#   agent_dir=/absolute/path/to/a/dedicated/pi/agent/directory
#   model=<provider>/<model-id>
#   context_window=<positive integer>
#   effort=medium
#   boundary_percent=60
#   keep_recent_tokens=<positive integer below the boundary>
#
# The configured agent directory remains operator-owned and may contain auth,
# skills, prompts, and themes. Its settings.json must already contain the exact
# derived compaction values. FirstMate only validates it; it never edits it.
# Delegated launches use --no-approve and --no-extensions, so project-local Pi
# settings/resources and every discovered extension are ignored. fm-spawn then
# explicitly loads only its required extensions, including the profile guard.

fm_pi_profile_fail() {
  echo "error: delegated Pi profile: $*" >&2
  return 1
}

fm_pi_profile_load() { # <config-dir> <project-dir>
  local config_dir=$1 project_dir=$2 file line key value seen expected_keys
  local pi_real pi_package metadata settings
  file="$config_dir/pi-delegated-profile"
  [ -f "$file" ] || return 2

  FM_PI_COMMAND=
  FM_PI_VERSION=
  FM_PI_AGENT_DIR=
  FM_PI_MODEL=
  FM_PI_CONTEXT_WINDOW=
  FM_PI_EFFORT=
  FM_PI_BOUNDARY_PERCENT=
  FM_PI_KEEP_RECENT_TOKENS=
  seen=' '
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
      *=*) key=${line%%=*}; value=${line#*=} ;;
      *) fm_pi_profile_fail "invalid line in $file: $line"; return 1 ;;
    esac
    case "$key" in
      pi_command|pi_version|agent_dir|model|context_window|effort|boundary_percent|keep_recent_tokens) ;;
      *) fm_pi_profile_fail "unknown key '$key' in $file"; return 1 ;;
    esac
    case "$seen" in *" $key "*) fm_pi_profile_fail "duplicate key '$key' in $file"; return 1 ;; esac
    [ -n "$value" ] || { fm_pi_profile_fail "empty value for '$key' in $file"; return 1; }
    seen="$seen$key "
    case "$key" in
      pi_command) FM_PI_COMMAND=$value ;;
      pi_version) FM_PI_VERSION=$value ;;
      agent_dir) FM_PI_AGENT_DIR=$value ;;
      model) FM_PI_MODEL=$value ;;
      context_window) FM_PI_CONTEXT_WINDOW=$value ;;
      effort) FM_PI_EFFORT=$value ;;
      boundary_percent) FM_PI_BOUNDARY_PERCENT=$value ;;
      keep_recent_tokens) FM_PI_KEEP_RECENT_TOKENS=$value ;;
    esac
  done < "$file"
  expected_keys='pi_command pi_version agent_dir model context_window effort boundary_percent keep_recent_tokens'
  for key in $expected_keys; do
    case "$seen" in *" $key "*) ;; *) fm_pi_profile_fail "missing key '$key' in $file"; return 1 ;; esac
  done

  case "$FM_PI_COMMAND" in /*) ;; *) fm_pi_profile_fail "pi_command must be an absolute path"; return 1 ;; esac
  [ -x "$FM_PI_COMMAND" ] || { fm_pi_profile_fail "pi_command is not executable: $FM_PI_COMMAND"; return 1; }
  [ "$FM_PI_VERSION" = 0.81.1 ] || { fm_pi_profile_fail "unsupported pi_version '$FM_PI_VERSION' (expected 0.81.1)"; return 1; }
  case "$FM_PI_AGENT_DIR" in /*) ;; *) fm_pi_profile_fail "agent_dir must be an absolute path"; return 1 ;; esac
  [ -d "$FM_PI_AGENT_DIR" ] || { fm_pi_profile_fail "agent_dir does not exist: $FM_PI_AGENT_DIR"; return 1; }
  [ -f "$FM_PI_AGENT_DIR/settings.json" ] || { fm_pi_profile_fail "agent_dir is missing settings.json"; return 1; }
  case "$FM_PI_MODEL" in */?*) FM_PI_PROVIDER=${FM_PI_MODEL%%/*}; FM_PI_MODEL_ID=${FM_PI_MODEL#*/} ;;
    *) fm_pi_profile_fail "model must be an exact provider/model-id"; return 1 ;;
  esac
  case "$FM_PI_CONTEXT_WINDOW:$FM_PI_KEEP_RECENT_TOKENS" in
    *[!0-9:]*|:*|*:) fm_pi_profile_fail "context_window and keep_recent_tokens must be positive integers"; return 1 ;;
  esac
  [ "$FM_PI_CONTEXT_WINDOW" -gt 0 ] && [ "$FM_PI_KEEP_RECENT_TOKENS" -gt 0 ] \
    || { fm_pi_profile_fail "context_window and keep_recent_tokens must be positive"; return 1; }
  [ "$FM_PI_EFFORT" = medium ] || { fm_pi_profile_fail "effort must be medium"; return 1; }
  [ "$FM_PI_BOUNDARY_PERCENT" = 60 ] || { fm_pi_profile_fail "boundary_percent must be 60"; return 1; }
  FM_PI_THRESHOLD=$((FM_PI_CONTEXT_WINDOW * FM_PI_BOUNDARY_PERCENT / 100))
  FM_PI_RESERVE_TOKENS=$((FM_PI_CONTEXT_WINDOW - FM_PI_THRESHOLD))
  [ "$FM_PI_KEEP_RECENT_TOKENS" -lt "$FM_PI_THRESHOLD" ] \
    || { fm_pi_profile_fail "keep_recent_tokens must be below the compaction boundary"; return 1; }

  pi_real=$(node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$FM_PI_COMMAND") \
    || { fm_pi_profile_fail "cannot resolve pi_command"; return 1; }
  case "$pi_real" in */dist/cli.js) pi_package=${pi_real%/dist/cli.js} ;;
    *) fm_pi_profile_fail "pi_command is not the Pi coding-agent CLI"; return 1 ;;
  esac
  FM_PI_COMMAND=$pi_real
  [ "$(PI_PACKAGE_DIR= "$FM_PI_COMMAND" --version 2>/dev/null)" = "$FM_PI_VERSION" ] \
    || { fm_pi_profile_fail "pi_command does not report version $FM_PI_VERSION"; return 1; }
  metadata=$(PI_PACKAGE_DIR= node --input-type=module - "$pi_package" "$FM_PI_AGENT_DIR" "$FM_PI_PROVIDER" "$FM_PI_MODEL_ID" <<'NODE'
import { pathToFileURL } from "node:url";
const [pkg, agentDir, provider, modelId] = process.argv.slice(2);
const { ModelRuntime } = await import(pathToFileURL(`${pkg}/dist/index.js`));
const runtime = await ModelRuntime.create({
  authPath: `${agentDir}/auth.json`,
  modelsPath: `${agentDir}/models.json`,
  allowModelNetwork: false,
});
if (runtime.getError()) throw new Error(runtime.getError());
const model = runtime.getModel(provider, modelId);
if (!model) throw new Error(`unknown model ${provider}/${modelId}`);
const supportsMedium = model.reasoning && model.thinkingLevelMap?.medium !== null;
process.stdout.write(`${model.provider}\t${model.id}\t${model.contextWindow}\t${supportsMedium}`);
NODE
  ) || { fm_pi_profile_fail "could not resolve effective model metadata without a provider request"; return 1; }
  [ "$metadata" = "$FM_PI_PROVIDER"$'\t'"$FM_PI_MODEL_ID"$'\t'"$FM_PI_CONTEXT_WINDOW"$'\t'true ] \
    || { fm_pi_profile_fail "effective model metadata mismatch (resolved $metadata)"; return 1; }

  settings=$(PI_PACKAGE_DIR= node --input-type=module - "$pi_package" "$FM_PI_AGENT_DIR" "$project_dir" <<'NODE'
import { pathToFileURL } from "node:url";
const [pkg, agentDir, cwd] = process.argv.slice(2);
const { SettingsManager } = await import(pathToFileURL(`${pkg}/dist/index.js`));
const manager = SettingsManager.create(cwd, agentDir, { projectTrusted: false });
const c = manager.getCompactionSettings();
process.stdout.write(`${c.enabled}\t${c.reserveTokens}\t${c.keepRecentTokens}`);
NODE
  ) || { fm_pi_profile_fail "could not resolve controlled settings"; return 1; }
  [ "$settings" = "true"$'\t'"$FM_PI_RESERVE_TOKENS"$'\t'"$FM_PI_KEEP_RECENT_TOKENS" ] \
    || { fm_pi_profile_fail "controlled compaction mismatch (resolved $settings; expected true, $FM_PI_RESERVE_TOKENS, $FM_PI_KEEP_RECENT_TOKENS)"; return 1; }
  return 0
}
