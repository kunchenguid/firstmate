#!/usr/bin/env bash
set -euo pipefail
A=$(cd "$(dirname "$0")/.." && pwd -P); T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/home/state" "$T/home/bin"
printf '#!/bin/sh\nexit 0\n' > "$T/home/bin/fm-check-register.sh"
cat > "$T/home/bin/fm-check-unregister.sh" <<'UNREGISTER'
#!/bin/sh
rm -f "$FM_HOME/state/$1.check.sh" "$FM_HOME/state/$1.check-trust"
UNREGISTER
chmod +x "$T/home/bin/"fm-check-*.sh; printf other > "$T/home/state/other"; touch "$T/home/state/zai-quota.check-trust"
E=(env HOME="$T/user" XDG_DATA_HOME="$T/data" FM_HOME="$T/home"); "${E[@]}" "$A/install.sh" >/dev/null; "${E[@]}" "$A/uninstall.sh" >/dev/null; [ ! -e "$T/home/state/zai-quota.check.sh" ] && [ ! -e "$T/home/state/zai-quota.check-trust" ] && [ "$(cat "$T/home/state/other")" = other ]; "${E[@]}" "$A/uninstall.sh" >/dev/null; echo 'PASS zai-quota-check uninstall'
