#!/usr/bin/env bash
set -euo pipefail
A=$(cd "$(dirname "$0")/.." && pwd -P); T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/home/bin" "$T/home/state"
printf '#!/bin/sh\nexit 0\n' > "$T/home/bin/fm-check-register.sh"
cat > "$T/home/bin/fm-check-unregister.sh" <<'UNREGISTER'
#!/bin/sh
rm -f "$FM_HOME/state/$1.check.sh" "$FM_HOME/state/$1.check-trust"
UNREGISTER
chmod +x "$T/home/bin/"fm-check-*.sh; printf unrelated > "$T/home/state/other"; touch "$T/home/state/0-nm-drain.check-trust"
E=(env HOME="$T/user" XDG_DATA_HOME="$T/data"); "${E[@]}" "$A/install.sh" "$T/home" >/dev/null; out=$("${E[@]}" "$A/uninstall.sh" "$T/home"); [[ "$out" == *'prior nm-quiet'* ]]; [ ! -e "$T/home/state/0-nm-drain.check.sh" ] && [ ! -e "$T/home/state/0-nm-drain.check-trust" ] && [ ! -e "$T/data/fm-nm-drain/nm-drain.sh" ] && [ "$(cat "$T/home/state/other")" = unrelated ]; "${E[@]}" "$A/uninstall.sh" "$T/home" >/dev/null; echo 'PASS nm-drain uninstall'
