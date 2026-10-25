#!/usr/bin/env bash
# Remove the pipeline quota-failover key and installed wrapper. Usage: uninstall.sh [--dry-run] [--config <path>] [--home <dir>]
set -euo pipefail
dry=0; root=${HOME:?}/.local/share/fm-pipeline-quota-failover; config=${NM_CONFIG:-$HOME/.no-mistakes/config.yaml}
while [ "$#" -gt 0 ]; do case "$1" in --dry-run) dry=1 ;; --config) config=${2:?--config needs a path}; shift ;; --home) root=${2:?--home needs a path}; shift ;; *) echo 'usage: uninstall.sh [--dry-run] [--config <path>] [--home <dir>]' >&2; exit 2 ;; esac; shift; done
wrapper=$root/pi-quota-failover
[ -f "$config" ] || { echo "uninstall.sh: no config at $config" >&2; exit 1; }
have=$(python3 -c 'import yaml,sys; c=yaml.safe_load(open(sys.argv[1])); print((c.get("agent_path_override") or {}).get("pi") or "")' "$config" 2>/dev/null) || { echo "uninstall.sh: cannot parse $config with python3-yaml" >&2; exit 1; }
if [ "$have" = "$wrapper" ]; then
  if [ "$dry" = 1 ]; then echo "dry-run: would remove agent_path_override.pi from $config"; else
    cp -p "$config" "$config.bak-pqf-uninstall-$(date +%s)"
    python3 - "$config" "$wrapper" <<'PY'
import re, sys
path, wrapper = sys.argv[1:]
lines = open(path).readlines()
pattern = re.compile(r'^  pi:\s*' + re.escape(wrapper) + r'\s*(?:#.*)?(?:\n)?$')
out = [line for line in lines if not pattern.match(line)]
for i, line in enumerate(out):
    if re.match(r'^agent_path_override:\s*(?:#.*)?(?:\n)?$', line):
        j = i + 1
        while j < len(out) and (out[j].startswith((' ', '\t')) or not out[j].strip()):
            j += 1
        if not any(x.startswith((' ', '\t')) and x.strip() and not x.lstrip().startswith('#') for x in out[i + 1:j]):
            del out[i:j]
        break
open(path, 'w').writelines(out)
PY
  fi
fi
if [ -e "$wrapper" ]; then echo "remove: $wrapper"; [ "$dry" -eq 1 ] || rm -f -- "$wrapper"; fi
[ "$dry" -eq 1 ] || rmdir "$root" 2>/dev/null || true
[ "$dry" -eq 1 ] || [ "$have" != "$wrapper" ] || echo "restored config backup: $config.bak-pqf-uninstall-*"
[ "$dry" -eq 0 ] || echo 'dry-run: nothing written'
