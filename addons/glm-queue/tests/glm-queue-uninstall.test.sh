#!/usr/bin/env bash
set -euo pipefail
A=$(cd "$(dirname "$0")/.." && pwd -P); T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/home/.config/systemd/user" "$T/home/.local/bin" "$T/bin"; cat > "$T/bin/systemctl" <<'STUB'
#!/bin/sh
echo "$*" >> "$SYSTEMCTL_LOG"
STUB
chmod +x "$T/bin/systemctl"; printf unrelated > "$T/home/.local/bin/keep"
E=(env HOME="$T/home" XDG_CONFIG_HOME="$T/home/.config" XDG_DATA_HOME="$T/home/.local/share" PATH="$T/bin:$PATH" SYSTEMCTL_LOG="$T/log")
"${E[@]}" "$A/install.sh" --max 2 >/dev/null; "${E[@]}" "$A/uninstall.sh" > "$T/out"
[ ! -e "$T/home/.config/systemd/user/fm-glm-queue.service" ] && [ ! -e "$T/home/.local/share/fm-glm-queue/glm-queue.mjs" ] && [ "$(cat "$T/home/.local/bin/keep")" = unrelated ] && grep -q 'disable --now fm-glm-queue.service' "$T/log" && grep -q 'prior unit contents are not known' "$T/out"
before=$(sha256sum "$T/log"); "${E[@]}" "$A/uninstall.sh" >/dev/null; [ "$before" = "$(sha256sum "$T/log")" ]; echo 'PASS glm-queue uninstall'
