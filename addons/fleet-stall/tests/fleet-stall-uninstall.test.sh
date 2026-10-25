#!/usr/bin/env bash
set -euo pipefail
A=$(cd "$(dirname "$0")/.." && pwd -P); T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/home/bin" "$T/home/state"
printf '#!/bin/sh\nexit 0\n' > "$T/home/bin/fm-check-register.sh"
cat > "$T/home/bin/fm-check-unregister.sh" <<'UNREGISTER'
#!/bin/sh
rm -f "$FM_HOME/state/$1.check.sh" "$FM_HOME/state/$1.check-trust"
UNREGISTER
chmod +x "$T/home/bin/"fm-check-*.sh; printf keep > "$T/home/state/other"; touch "$T/home/state/fleet-stall.check-trust"
E=(env HOME="$T/user" XDG_DATA_HOME="$T/data" FM_HOME="$T/home"); "${E[@]}" "$A/install.sh" >/dev/null; "${E[@]}" "$A/uninstall.sh" >/dev/null; [ ! -e "$T/home/state/fleet-stall.check.sh" ] && [ ! -e "$T/home/state/fleet-stall.check-trust" ] && [ ! -e "$T/data/fm-fleet-stall/fleet-stall-check" ] && [ "$(cat "$T/home/state/other")" = keep ]; "${E[@]}" "$A/uninstall.sh" >/dev/null; echo 'PASS fleet-stall uninstall'
