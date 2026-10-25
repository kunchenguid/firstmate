#!/usr/bin/env bash
set -euo pipefail
A=$(cd "$(dirname "$0")/.." && pwd -P); T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/home" "$T/bin" "$T/config/systemd/user" "$T/config/systemd/user/fm.slice.d"
cat >"$T/bin/systemctl" <<'SYSTEMCTL'
#!/bin/sh
echo "$*" >>"$LOG"
SYSTEMCTL
chmod +x "$T/bin/systemctl"
E=(env HOME="$T/home" XDG_DATA_HOME="$T/data" XDG_CONFIG_HOME="$T/config" PATH="$T/bin:$PATH" LOG="$T/systemctl.log")
cat >"$T/config/systemd/user/fm-heavy.slice" <<'SLICE'
[Slice]
MemoryHigh=32G
MemoryMax=38G
MemorySwapMax=24G
SLICE
cp "$T/config/systemd/user/fm-heavy.slice" "$T/heavy.before"
printf 'unrelated drop-in\n' >"$T/config/systemd/user/fm.slice.d/other.conf"
printf unrelated >"$T/keep"
"${E[@]}" "$A/install.sh" >/dev/null
expected=$'[Slice]\nCPUWeight=20\nIOWeight=20'
[ "$(cat "$T/config/systemd/user/fm.slice.d/50-fm-heavy-weight.conf")" = "$expected" ]
[ "$(cat "$T/config/systemd/user/fm-heavy.slice.d/50-fm-heavy-weight.conf")" = "$expected" ]
cmp -s "$T/config/systemd/user/fm-heavy.slice" "$T/heavy.before"
"${E[@]}" "$A/uninstall.sh" >/dev/null
[ ! -e "$T/data/fm-host-memory/fm-mem-gate.sh" ]
[ ! -e "$T/config/systemd/user/fm.slice.d/50-fm-heavy-weight.conf" ]
[ ! -e "$T/config/systemd/user/fm-heavy.slice.d/50-fm-heavy-weight.conf" ]
cmp -s "$T/config/systemd/user/fm-heavy.slice" "$T/heavy.before"
[ "$(cat "$T/config/systemd/user/fm.slice.d/other.conf")" = 'unrelated drop-in' ]
[ "$(cat "$T/keep")" = unrelated ]
[ "$(grep -cx -- '--user daemon-reload' "$T/systemctl.log")" = 2 ]
before=$(sha256sum "$T/keep"); "${E[@]}" "$A/uninstall.sh" >/dev/null; [ "$before" = "$(sha256sum "$T/keep")" ]
echo 'PASS host-memory install/uninstall preserves existing slice policy'
