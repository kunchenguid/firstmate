#!/usr/bin/env bash
# Install or remove the pi-quota-failover wrapper for the no-mistakes
# pipeline agent, and wire it in with one key-level edit of
# ~/.no-mistakes/config.yaml (or $NM_CONFIG).
#
#   install.sh [--dry-run] [--restore] [--config <path>] [--home <dir>]
#
# --dry-run   print the changes and write nothing.
# --restore   remove agent_path_override.pi and the installed copy.
# --home      alternate install dir (default ~/.local/share/fm-pipeline-quota-failover)
#
# The edit never prints the config or any value in it; it reports only the
# key name and the wrapper path it wrote. A timestamped backup of the config
# is written next to it before the first change. The no-mistakes daemon
# re-reads the config per run, so no daemon restart is needed or performed.
set -u

die() { echo "install.sh: $*" >&2; exit 1; }

dry=0 restore=0
install_root=${HOME:?}/.local/share/fm-pipeline-quota-failover
config=${NM_CONFIG:-${HOME:?}/.no-mistakes/config.yaml}
while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) dry=1 ;;
    --restore) restore=1 ;;
    --config) config=$2; shift ;;
    --home) install_root=$2; shift ;;
    *) die "unknown argument: $1 (use --dry-run, --restore, --config <path>, --home <dir>)" ;;
  esac
  shift
done

src=$(cd "$(dirname "$0")" && pwd)/pi-quota-failover
[ -f "$src" ] || die "wrapper not found next to install.sh"
[ -f "$config" ] || die "no config at $config"

wrapper=$install_root/pi-quota-failover

if [ "$restore" = 1 ]; then
  [ "$(python3 -c 'import yaml,sys; c=yaml.safe_load(open(sys.argv[1])); print((c.get("agent_path_override") or {}).get("pi") or "")' "$config" 2>/dev/null)" = "$wrapper" ] \
    || die "agent_path_override.pi is not $wrapper; nothing to restore"
  if [ "$dry" = 1 ]; then echo "dry-run: would remove key agent_path_override.pi and $wrapper"; exit 0; fi
  cp -p "$config" "$config.bak-pqf-restore-$(date +%s)" || die "cannot back up $config"
  python3 - "$config" <<'EOF'
import sys, re
path = sys.argv[1]
lines = open(path).read().splitlines(keepends=True)
out, i, removed = [], 0, False
while i < len(lines):
    line = lines[i]
    if re.match(r'^agent_path_override:', line):
        i += 1
        while i < len(lines) and (lines[i].startswith((' ', '\t')) or lines[i].strip() == ''):
            i += 1
        removed = True
        continue
    out.append(line)
    i += 1
if not removed:
    sys.exit("config has no active agent_path_override block")
open(path, 'w').write(''.join(out))
EOF
  rm -f "$wrapper"
  echo "removed key agent_path_override.pi and $wrapper (backup written next to the config)"
  exit 0
fi

have=$(python3 -c 'import yaml,sys; c=yaml.safe_load(open(sys.argv[1])); print((c.get("agent_path_override") or {}).get("pi") or "")' "$config" 2>/dev/null) \
  || die "cannot parse $config with python3-yaml"
if [ -n "$have" ] && [ "$have" != "$wrapper" ]; then
  die "agent_path_override.pi already points at $have; refusing to replace it (restore first)"
fi

if [ "$dry" = 1 ]; then
  echo "dry-run: would copy $src -> $wrapper"
  if [ -z "$have" ]; then
    echo "dry-run: would add key agent_path_override.pi = $wrapper to $config (backup first)"
  else
    echo "dry-run: key agent_path_override.pi is already $wrapper; config unchanged"
  fi
  exit 0
fi

mkdir -p "$install_root" || die "cannot create $install_root"
tmp_wrapper=$install_root/.pi-quota-failover.$$
if ! cp -p "$src" "$tmp_wrapper" || ! chmod +x "$tmp_wrapper" || ! mv -f "$tmp_wrapper" "$wrapper"; then
  rm -f -- "$tmp_wrapper"
  die "cannot atomically install wrapper at $wrapper"
fi

if [ -z "$have" ]; then
  cp -p "$config" "$config.bak-pqf-$(date +%Y%m%d-%H%M%S)" || die "cannot back up $config"
  # Key-level edit: append the new top-level key at the end of the document
  # (YAML keys are order-free, so nothing else in the file moves or changes).
  python3 - "$config" "$wrapper" <<'EOF'
import sys
path, wrapper = sys.argv[1], sys.argv[2]
text = open(path).read()
if not text.endswith('\n'):
    text += '\n'
text += '\nagent_path_override:\n  pi: ' + wrapper + '\n'
open(path, 'w').write(text)
EOF
  echo "added key agent_path_override.pi = $wrapper to $config (backup written next to it)"
else
  echo "key agent_path_override.pi already $wrapper; config unchanged"
fi
echo "installed $wrapper; the next pipeline run picks it up (no daemon restart needed)"
